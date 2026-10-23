// Indigo HID injection, modeled on facebook/idb's FBSimulatorHID and
// FBSimulatorIndigoHID (MIT License, Copyright (c) Meta Platforms, Inc. and
// affiliates). Xcode 27 builds complete messages in SimulatorKit, so instead of
// hand-assembling Indigo structs we call its builders and send the result.
#import "Internal.h"

static const uint32_t SBIndigoOperationDown = 1;
static const uint32_t SBIndigoOperationUp = 2;

@implementation SBHIDClient {
  id<SBSimDeviceLegacyHIDClient> _client;
  dispatch_queue_t _queue;
}

- (nullable instancetype)initWithDevice:(SBDevice *)device error:(NSError **)error {
  if (!SBLoadFrameworks(error)) {
    return nil;
  }
  Class clientClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
  if (!clientClass) {
    if (error) {
      *error = SBError(SBErrorFrameworkMissing, @"SimulatorKit.SimDeviceLegacyHIDClient is unavailable in this Xcode.");
    }
    return nil;
  }
  id<SBSimDeviceLegacyHIDClient> client = nil;
  @try {
    client = [(id<SBSimDeviceLegacyHIDClient>)[clientClass alloc] initWithDevice:device.simDevice error:error];
  } @catch (NSException *exception) {
    if (error) {
      *error = SBExceptionError(exception, @"connecting to the simulator's HID service");
    }
  }
  if (!client) {
    return nil;
  }
  self = [super init];
  if (self) {
    _client = client;
    _queue = dispatch_queue_create("glovebox.hid", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)send:(void *_Nullable)message completion:(void (^)(NSError *_Nullable))completion {
  completion = SBOnce(completion);
  if (!message) {
    completion(SBError(SBErrorThrottled, @"SimulatorKit did not build the HID message."));
    return;
  }
  @try {
    [_client sendWithMessage:message freeWhenDone:YES completionQueue:_queue completion:completion];
  } @catch (NSException *exception) {
    // Whether SimulatorKit took ownership of the message is unknown, so it is
    // leaked rather than risk a double free.
    completion(SBExceptionError(exception, @"sending input"));
  }
}

- (void)sendTouchPhase:(SBTouchPhase)phase
                 ratio:(CGPoint)ratio
                target:(uint32_t)target
            completion:(void (^)(NSError *_Nullable))completion {
  CGPoint point = ratio;
  // A 1x1 size makes SimulatorKit use `point` as the ratio, as Simulator.app
  // did. Edge 0 means the touch does not start at a screen edge.
  [self send:SBIndigo.mouse(&point, NULL, target, phase, CGSizeMake(1, 1), 0) completion:completion];
}

- (void)sendKeyUsage:(uint32_t)usage down:(BOOL)down completion:(void (^)(NSError *_Nullable))completion {
  [self send:SBIndigo.keyboard(usage, down ? SBIndigoOperationDown : SBIndigoOperationUp) completion:completion];
}

- (void)sendButtonSource:(uint32_t)source
                    down:(BOOL)down
                  target:(uint32_t)target
              completion:(void (^)(NSError *_Nullable))completion {
  [self send:SBIndigo.button(source, down ? SBIndigoOperationDown : SBIndigoOperationUp, target) completion:completion];
}

@end
