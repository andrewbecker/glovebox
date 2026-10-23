// Accessibility tree reading via AccessibilityPlatformTranslation, ported from
// facebook/idb's FBSimulatorAccessibilityCommands (MIT License, Copyright (c)
// Meta Platforms, Inc. and affiliates).
//
// AXPTranslator is a process-wide singleton. It asks its token delegate for a
// callback per token, and that callback forwards each request to the matching
// simulator over CoreSimulator and blocks until the response arrives. Every
// attribute read is one such round trip, so all work runs on a private queue.
#import <os/lock.h>

#import "Internal.h"

static const int64_t SBAccessibilityRequestTimeout = 5 * NSEC_PER_SEC;

/// The simulator behind one token, and whether the current read has stalled.
/// A tree read makes several requests per element, so after one times out
/// the rest fail at once instead of each waiting out the timeout. (A hung app
/// usually gets an empty answer from the simulator after about 3 s instead;
/// see `answered:`. This covers a simulator that does not answer at all.)
@interface SBAXTarget : NSObject
- (instancetype)initWithDevice:(id<SBSimDevice>)device;
@property (nonatomic, readonly) id<SBSimDevice> device;
@property (atomic) BOOL stalled;
@end

@implementation SBAXTarget
- (instancetype)initWithDevice:(id<SBSimDevice>)device {
  self = [super init];
  if (self) {
    _device = device;
  }
  return self;
}
@end

@interface SBAXDispatcher : NSObject
+ (instancetype)shared;
- (void)registerTarget:(SBAXTarget *)target forToken:(NSString *)token;
@end

@implementation SBAXDispatcher {
  os_unfair_lock _lock;
  NSMutableDictionary<NSString *, SBAXTarget *> *_targets;
  dispatch_queue_t _responseQueue;
}

+ (instancetype)shared {
  static SBAXDispatcher *dispatcher;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatcher = [SBAXDispatcher new];
  });
  return dispatcher;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _targets = [NSMutableDictionary dictionary];
    _responseQueue = dispatch_queue_create("glovebox.accessibility.responses", DISPATCH_QUEUE_CONCURRENT);
  }
  return self;
}

- (void)registerTarget:(SBAXTarget *)target forToken:(NSString *)token {
  os_unfair_lock_lock(&_lock);
  _targets[token] = target;
  os_unfair_lock_unlock(&_lock);
}

// AXPTranslationTokenDelegateHelper

- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
  os_unfair_lock_lock(&_lock);
  SBAXTarget *target = _targets[token];
  os_unfair_lock_unlock(&_lock);
  dispatch_queue_t responseQueue = _responseQueue;
  return ^id(id request) {
    if (!target || target.stalled) {
      return nil;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block id response = nil;
    [target.device sendAccessibilityRequestAsync:request
                                 completionQueue:responseQueue
                               completionHandler:^(id _Nullable innerResponse) {
                                 response = innerResponse;
                                 dispatch_semaphore_signal(done);
                               }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, SBAccessibilityRequestTimeout)) != 0) {
      target.stalled = YES;
      return nil;
    }
    return response;
  };
}

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token {
  // Keep frames in device points, the coordinate space taps use.
  return rect;
}

- (nullable id)accessibilityTranslationRootParentWithToken:(NSString *)token {
  return nil;
}

@end

static dispatch_queue_t SBAccessibilityQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("glovebox.accessibility", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static id<SBAXPTranslator> SBTranslator(void) {
  static id<SBAXPTranslator> translator;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class<SBAXPTranslator> translatorClass = (Class<SBAXPTranslator>)NSClassFromString(@"AXPTranslator");
    translator = [translatorClass sharedInstance];
    translator.bridgeTokenDelegate = SBAXDispatcher.shared;
    translator.supportsDelegateTokens = YES;
    translator.accessibilityEnabled = YES;
  });
  return translator;
}

static NSString *_Nullable SBStringValue(id _Nullable value) {
  if (!value || value == NSNull.null) {
    return nil;
  }
  if ([value isKindOfClass:NSString.class]) {
    return [value length] > 0 ? value : nil;
  }
  if ([value isKindOfClass:NSAttributedString.class]) {
    NSString *string = [value string];
    return string.length > 0 ? string : nil;
  }
  if ([value isKindOfClass:NSNumber.class]) {
    return [value stringValue];
  }
  return [value description];
}

static NSNumber *SBRound(CGFloat value) {
  return @(round(value * 10) / 10);
}

@implementation SBAccessibility {
  NSString *_token;
  SBAXTarget *_target;
}

- (instancetype)initWithDevice:(SBDevice *)device {
  self = [super init];
  if (self) {
    _token = NSUUID.UUID.UUIDString;
    _target = [[SBAXTarget alloc] initWithDevice:device.simDevice];
  }
  return self;
}

/// Called at the start of every read, on the accessibility queue.
- (nullable id<SBAXPTranslator>)prepare:(NSError **)error {
  if (!SBLoadFrameworks(error)) {
    return nil;
  }
  id<SBAXPTranslator> translator = SBTranslator();
  if (!translator) {
    if (error) {
      *error = SBError(SBErrorFrameworkMissing, @"AXPTranslator is unavailable on this macOS.");
    }
    return nil;
  }
  [SBAXDispatcher.shared registerTarget:_target forToken:_token];
  _target.stalled = NO;
  return translator;
}

static NSError *SBNotResponding(void) {
  return SBError(SBErrorNotResponding,
                 @"The app did not answer accessibility requests. It may be busy or hung: try again, or take a screenshot.");
}

/// The error for a read that got no answer: the app not responding if a
/// request timed out, else `error`, else `message`.
- (NSError *)failure:(nullable NSError *)error message:(NSString *)message {
  if (_target.stalled) {
    return SBNotResponding();
  }
  return error ?: SBError(SBErrorAccessibility, @"%@", message);
}

/// An empty answer faster than this came from an app that is not ready (on
/// its launch screen, an app's root is 0x0 with no children, and it says so
/// at once). A hung app's empty answers take about 3 s.
static const NSTimeInterval SBNotReadyAnswerLimit = 1.5;

static NSError *SBNotReady(NSString *message) {
  return SBError(SBErrorNotReady, @"%@", message);
}

/// False when `node` came back empty because the app did not respond. A hung
/// app's requests return empty answers, which reads as an element with no
/// size and no children; a real element at a point, or an app's root, always
/// has a size.
- (BOOL)answered:(NSDictionary *)node {
  NSArray<NSNumber *> *frame = node[@"frame"];
  BOOL empty = frame[2].doubleValue == 0 && frame[3].doubleValue == 0 && node[@"children"] == nil;
  return !_target.stalled && !empty;
}

- (NSMutableDictionary *)serialize:(id<SBAXPMacPlatformElement>)element
                          children:(BOOL)includeChildren
                            budget:(NSInteger *)budget {
  element.translation.bridgeDelegateToken = _token;
  (*budget)--;
  NSMutableDictionary *node = [NSMutableDictionary dictionary];
  NSString *role = element.accessibilityRole;
  if ([role hasPrefix:@"AX"]) {
    role = [role substringFromIndex:2];
  }
  node[@"role"] = role ?: @"Unknown";
  node[@"label"] = SBStringValue(element.accessibilityLabel);
  node[@"value"] = SBStringValue(element.accessibilityValue);
  node[@"identifier"] = SBStringValue(element.accessibilityIdentifier);
  if ([role isEqualToString:@"TextField"] || [role isEqualToString:@"TextArea"] ||
      [role isEqualToString:@"SearchField"]) {
    node[@"placeholder"] = SBStringValue(element.accessibilityPlaceholderValue);
  }
  NSRect frame = element.accessibilityFrame;
  node[@"frame"] = @[SBRound(frame.origin.x), SBRound(frame.origin.y), SBRound(frame.size.width),
                     SBRound(frame.size.height)];
  // Where VoiceOver taps: on the switch of a switch row, whose frame spans
  // the row. Kept only when it is inside the frame and off center; text
  // fields report (0, 0).
  NSPoint activation = element.accessibilityActivationPoint;
  if (NSPointInRect(activation, frame) &&
      hypot(activation.x - NSMidX(frame), activation.y - NSMidY(frame)) > 1) {
    node[@"activation"] = @[SBRound(activation.x), SBRound(activation.y)];
  }
  node[@"enabled"] = @(element.isAccessibilityEnabled);
  if (includeChildren) {
    NSMutableArray *children = [NSMutableArray array];
    for (id<SBAXPMacPlatformElement> child in element.accessibilityChildren) {
      if (_target.stalled) {
        break;
      }
      if (*budget <= 0) {
        node[@"truncated"] = @YES;
        break;
      }
      [children addObject:[self serialize:child children:YES budget:budget]];
    }
    if (children.count > 0) {
      node[@"children"] = children;
    }
  }
  return node;
}

- (void)finish:(NSDictionary *)node completion:(void (^)(NSData *_Nullable, NSError *_Nullable))completion {
  NSError *jsonError = nil;
  NSData *json = [NSJSONSerialization dataWithJSONObject:node options:0 error:&jsonError];
  completion(json, jsonError);
}

- (void)frontmostTreeWithMaxElements:(NSInteger)maxElements
                          completion:(void (^)(NSData *_Nullable, NSError *_Nullable))completion {
  dispatch_async(SBAccessibilityQueue(), ^{
    @try {
      NSError *error = nil;
      NSDate *start = [NSDate date];
      id<SBAXPTranslator> translator = [self prepare:&error];
      id<SBAXPTranslationObject> application =
          [translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:self->_token];
      if (!application) {
        completion(nil, error || self->_target.stalled
                            ? [self failure:error message:@""]
                            : SBNotReady(@"No frontmost application yet. The simulator may still be booting."));
        return;
      }
      application.bridgeDelegateToken = self->_token;
      id<SBAXPMacPlatformElement> element = [translator macPlatformElementFromTranslation:application];
      NSInteger budget = maxElements > 0 ? maxElements : NSIntegerMax;
      NSMutableDictionary *tree = [self serialize:element children:YES budget:&budget];
      if (![self answered:tree]) {
        BOOL fast = -[start timeIntervalSinceNow] < SBNotReadyAnswerLimit;
        completion(nil, !self->_target.stalled && fast
                            ? SBNotReady(@"The app is NOT READY: its accessibility tree is empty, as while it shows its launch screen.")
                            : SBNotResponding());
        return;
      }
      tree[@"pid"] = @(application.pid);
      [self finish:tree completion:completion];
    } @catch (NSException *exception) {
      completion(nil, SBExceptionError(exception, @"reading the accessibility tree"));
    }
  });
}

- (void)frontmostApplicationPIDWithCompletion:(void (^)(NSInteger, NSError *_Nullable))completion {
  dispatch_async(SBAccessibilityQueue(), ^{
    @try {
      NSError *error = nil;
      id<SBAXPTranslator> translator = [self prepare:&error];
      id<SBAXPTranslationObject> application =
          [translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:self->_token];
      if (!application) {
        completion(0, [self failure:error message:@"No frontmost application."]);
        return;
      }
      completion(application.pid, nil);
    } @catch (NSException *exception) {
      completion(0, SBExceptionError(exception, @"finding the frontmost app"));
    }
  });
}

- (void)elementAtPoint:(CGPoint)point
             displayID:(uint32_t)displayID
            shownPoint:(CGPoint)shownPoint
            completion:(void (^)(NSData *_Nullable, NSError *_Nullable))completion {
  dispatch_async(SBAccessibilityQueue(), ^{
    @try {
      NSError *error = nil;
      id<SBAXPTranslator> translator = [self prepare:&error];
      id<SBAXPTranslationObject> hit = [translator objectAtPoint:point displayId:displayID bridgeDelegateToken:self->_token];
      if (!hit) {
        NSString *message = [NSString stringWithFormat:@"No accessibility element at (%.0f, %.0f).", shownPoint.x, shownPoint.y];
        completion(nil, [self failure:error message:message]);
        return;
      }
      hit.bridgeDelegateToken = self->_token;
      id<SBAXPMacPlatformElement> element = [translator macPlatformElementFromTranslation:hit];
      NSInteger budget = 1;
      NSMutableDictionary *node = [self serialize:element children:NO budget:&budget];
      if (![self answered:node]) {
        completion(nil, SBNotResponding());
        return;
      }
      node[@"pid"] = @(hit.pid);
      [self finish:node completion:completion];
    } @catch (NSException *exception) {
      completion(nil, SBExceptionError(exception, @"reading the element at a point"));
    }
  });
}

/// Most elements read from the subtrees of hit-tested containers, in all
/// and in one container.
static const NSInteger SBSubtreeBudget = 1500;
static const NSInteger SBSubtreeLimit = 600;

/// Adds every descendant of `tree` not seen yet to `nodes`, flattened. Each
/// leaf with text or an identifier adds its rect to `covered`.
- (void)appendDescendantsOf:(NSDictionary *)tree
                        pid:(int)pid
                         to:(NSMutableArray *)nodes
                       seen:(NSMutableSet *)seen
                    covered:(NSMutableArray<NSValue *> *)covered
             containerRoles:(NSSet<NSString *> *)containerRoles {
  for (NSDictionary *child in tree[@"children"]) {
    NSMutableDictionary *node = [child mutableCopy];
    [node removeObjectForKey:@"children"];
    NSArray *frame = node[@"frame"];
    if (frame.count != 4) {
      continue;
    }
    NSArray *key = @[[@"AX" stringByAppendingString:node[@"role"]], frame[0], frame[1], frame[2], frame[3]];
    if (![seen containsObject:key]) {
      [seen addObject:key];
      node[@"pid"] = @(pid);
      [nodes addObject:node];
      BOOL hasContent = node[@"label"] || node[@"value"] || node[@"identifier"];
      if (!child[@"children"] && hasContent && ![containerRoles containsObject:node[@"role"]]) {
        [covered addObject:[NSValue valueWithRect:CGRectMake([frame[0] doubleValue], [frame[1] doubleValue],
                                                             [frame[2] doubleValue], [frame[3] doubleValue])]];
      }
    }
    [self appendDescendantsOf:child pid:pid to:nodes seen:seen covered:covered containerRoles:containerRoles];
  }
}

- (void)elementsAtPoints:(NSArray<NSValue *> *)points
             shownPoints:(NSArray<NSValue *> *)shownPoints
               displayID:(uint32_t)displayID
          containerRoles:(NSSet<NSString *> *)containerRoles
               timeLimit:(NSTimeInterval)timeLimit
              completion:(void (^)(NSData *_Nullable, NSError *_Nullable))completion {
  dispatch_async(SBAccessibilityQueue(), ^{
    @try {
      NSError *error = nil;
      id<SBAXPTranslator> translator = [self prepare:&error];
      if (!translator) {
        completion(nil, error);
        return;
      }
      NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeLimit];
      NSMutableArray *nodes = [NSMutableArray array];
      NSMutableSet *seen = [NSMutableSet set];
      NSInteger subtreeBudget = SBSubtreeBudget;
      // Leaves found so far, in interface points.
      NSMutableArray<NSValue *> *covered = [NSMutableArray array];
      for (NSUInteger index = 0; index < points.count; index++) {
        if (self->_target.stalled || deadline.timeIntervalSinceNow < 0) {
          break;
        }
        CGPoint shown = index < shownPoints.count ? shownPoints[index].pointValue : CGPointMake(-1, -1);
        BOOL inside = NO;
        for (NSValue *rect in covered) {
          if (CGRectContainsPoint(rect.rectValue, shown)) {
            inside = YES;
            break;
          }
        }
        if (inside) {
          continue;
        }
        id<SBAXPTranslationObject> hit = [translator objectAtPoint:points[index].pointValue
                                                         displayId:displayID
                                               bridgeDelegateToken:self->_token];
        if (!hit) {
          continue;
        }
        hit.bridgeDelegateToken = self->_token;
        id<SBAXPMacPlatformElement> element = [translator macPlatformElementFromTranslation:hit];
        element.translation.bridgeDelegateToken = self->_token;
        // Most points land on an element already found (a container, or the
        // app itself in empty space). Its role and frame tell, in two round
        // trips instead of the eight of a full read.
        NSString *hitRole = element.accessibilityRole ?: @"";
        NSRect hitFrame = element.accessibilityFrame;
        if ([hitRole isEqualToString:@"AXApplication"] || (hitFrame.size.width == 0 && hitFrame.size.height == 0)) {
          continue;
        }
        NSArray *early = @[hitRole, SBRound(hitFrame.origin.x), SBRound(hitFrame.origin.y), SBRound(hitFrame.size.width),
                           SBRound(hitFrame.size.height)];
        if ([seen containsObject:early]) {
          continue;
        }
        [seen addObject:early];
        NSInteger budget = 1;
        NSMutableDictionary *node = [self serialize:element children:NO budget:&budget];
        if (![self answered:node]) {
          continue;
        }
        NSArray *frame = node[@"frame"];
        BOOL hasContent = node[@"label"] || node[@"value"] || node[@"identifier"];
        if (frame.count == 4 && hasContent && ![containerRoles containsObject:node[@"role"]]) {
          CGRect rect = CGRectMake([frame[0] doubleValue], [frame[1] doubleValue], [frame[2] doubleValue],
                                   [frame[3] doubleValue]);
          // A frame that misses the point it was hit at says nothing about
          // the points around it.
          if (CGRectContainsPoint(rect, shown)) {
            [covered addObject:[NSValue valueWithRect:rect]];
          }
        }
        node[@"at"] = @[SBRound(shown.x), SBRound(shown.y)];
        node[@"pid"] = @(hit.pid);
        [nodes addObject:node];
        // A container found this way (a web page) can often be read as a
        // subtree: one walk instead of a hit-test at every element inside
        // it. Its leaves then cover their own rects. The container covers
        // nothing: the iPhone Duo's Settings sidebar gives only some of its
        // rows as children (2026-10-23), so the rest still need points.
        if (subtreeBudget > 0 && [containerRoles containsObject:node[@"role"]]) {
          NSInteger budget = MIN(subtreeBudget, SBSubtreeLimit);
          NSInteger start = budget;
          NSDictionary *tree = [self serialize:element children:YES budget:&budget];
          subtreeBudget -= start - budget;
          [self appendDescendantsOf:tree pid:hit.pid to:nodes seen:seen covered:covered containerRoles:containerRoles];
        }
      }
      NSError *jsonError = nil;
      NSData *json = [NSJSONSerialization dataWithJSONObject:nodes options:0 error:&jsonError];
      completion(json, jsonError);
    } @catch (NSException *exception) {
      completion(nil, SBExceptionError(exception, @"hit-testing the screen"));
    }
  });
}

@end
