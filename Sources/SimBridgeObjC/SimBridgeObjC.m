#import "SimBridgeObjC.h"

#import <IOSurface/IOSurfaceRef.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdatomic.h>

#import "Internal.h"

NSErrorDomain const SBErrorDomain = @"glovebox.SimBridge";

NSError *SBError(SBErrorCode code, NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  return [NSError errorWithDomain:SBErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSError *SBExceptionError(NSException *exception, NSString *during) {
  return SBError(SBErrorException, @"A simulator framework raised %@ while %@: %@. A new Xcode may have changed it.",
                 exception.name, during, exception.reason ?: @"no reason given");
}

void (^SBOnce(void (^completion)(NSError *_Nullable)))(NSError *_Nullable) {
  __block atomic_bool called = false;
  return ^(NSError *_Nullable error) {
    if (!atomic_exchange(&called, true)) {
      completion(error);
    }
  };
}

NSString *_Nullable SBDeveloperDirectory(void) {
  static NSString *path;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // As xcrun looks: $DEVELOPER_DIR, then xcode-select's link (no process),
    // then xcode-select itself.
    NSString *environment = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    if (environment.length > 0) {
      path = environment;
      return;
    }
    NSString *link = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:@"/var/db/xcode_select_link" error:NULL];
    if (link.length > 0) {
      path = link;
      return;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    task.arguments = @[@"-p"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) {
      return;
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    output = [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    path = output.length > 0 ? output : nil;
  });
  return path;
}

NSString *_Nullable SBCoreSimulatorVersion(void) {
  // The Xcode installer replaces CoreSimulator in place, so its version can
  // be ahead of the selected Xcode: read the framework, not Xcode.
  NSBundle *bundle = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework"];
  return [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
}

static void *SBOpen(NSString *path, NSMutableArray<NSString *> *failures) {
  void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!handle) {
    [failures addObject:[NSString stringWithFormat:@"%@ (%s)", path, dlerror()]];
  }
  return handle;
}

BOOL SBLoadFrameworks(NSError **error) {
  static NSError *loadError;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *developerDir = SBDeveloperDirectory();
    if (!developerDir) {
      loadError = SBError(SBErrorFrameworkMissing, @"xcode-select -p failed. Install Xcode and run xcode-select -s.");
      return;
    }
    NSString *xcodeContents = developerDir.stringByDeletingLastPathComponent;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    SBOpen(@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", failures);
    void *simulatorKit = SBOpen([xcodeContents stringByAppendingPathComponent:@"SharedFrameworks/SimulatorKit.framework/SimulatorKit"], failures);
    SBOpen(@"/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", failures);
    if (simulatorKit) {
      SBIndigo.mouse = (SBIndigoMouseFn)dlsym(simulatorKit, "IndigoHIDMessageForMouseNSEvent");
      SBIndigo.keyboard = (SBIndigoKeyboardFn)dlsym(simulatorKit, "IndigoHIDMessageForKeyboardArbitrary");
      SBIndigo.button = (SBIndigoButtonFn)dlsym(simulatorKit, "IndigoHIDMessageForButton");
      if (!SBIndigo.mouse || !SBIndigo.keyboard || !SBIndigo.button) {
        [failures addObject:@"SimulatorKit is missing the IndigoHIDMessageFor* builders"];
      }
    }
    if (failures.count > 0) {
      loadError = SBError(SBErrorFrameworkMissing, @"Could not load simulator frameworks: %@",
                          [failures componentsJoinedByString:@"; "]);
    }
  });
  if (loadError && error) {
    *error = loadError;
  }
  return loadError == nil;
}

SBIndigoFunctions SBIndigo;

#pragma mark - SBDevice

@implementation SBDevice

+ (nullable instancetype)deviceWithUDID:(NSString *)udid error:(NSError **)error {
  if (!SBLoadFrameworks(error)) {
    return nil;
  }
  @try {
    Class<SBSimServiceContext> contextClass = (Class<SBSimServiceContext>)NSClassFromString(@"SimServiceContext");
    id<SBSimServiceContext> context = [contextClass sharedServiceContextForDeveloperDir:SBDeveloperDirectory() error:error];
    id<SBSimDeviceSet> deviceSet = [context defaultDeviceSetWithError:error];
    if (!deviceSet) {
      return nil;
    }
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:udid];
    for (id<SBSimDevice> device in deviceSet.devices) {
      if ([device.UDID isEqual:uuid]) {
        return [[self alloc] initWithSimDevice:device];
      }
    }
  } @catch (NSException *exception) {
    if (error) {
      *error = SBExceptionError(exception, @"looking up the simulator");
    }
    return nil;
  }
  if (error) {
    *error = SBError(SBErrorDeviceNotFound, @"No simulator with UDID %@. Call list_devices for valid UDIDs.", udid);
  }
  return nil;
}

- (instancetype)initWithSimDevice:(id<SBSimDevice>)device {
  self = [super init];
  if (self) {
    _simDevice = device;
  }
  return self;
}

- (NSString *)udid {
  return self.simDevice.UDID.UUIDString;
}

- (NSString *)name {
  return self.simDevice.name;
}

- (BOOL)isBooted {
  return [self.simDevice.stateString isEqualToString:@"Booted"];
}

- (nullable NSDate *)lastBootedAt {
  id<SBSimDevice> device = self.simDevice;
  return [device respondsToSelector:@selector(lastBootedAt)] ? device.lastBootedAt : nil;
}

- (NSArray<SBScreen *> *)screens {
  NSMutableArray<SBScreen *> *screens = [NSMutableArray array];
  Protocol *screenProtocol = objc_getProtocol("SimScreen");
  @try {
    for (id<SBSimDeviceIOPort> port in self.simDevice.io.ioPorts) {
      // Ports are ROCK remote proxies: KVC fails on them, plain messages work.
      if (![port respondsToSelector:@selector(descriptor)]) {
        continue;
      }
      id descriptor = port.descriptor;
      if (![descriptor conformsToProtocol:screenProtocol] || ![descriptor respondsToSelector:@selector(framebufferSurface)]) {
        continue;
      }
      [screens addObject:[[SBScreen alloc] initWithDescriptor:descriptor]];
    }
  } @catch (NSException *exception) {
    // Callers treat no screens as a display that is not ready yet.
    NSLog(@"glovebox: %@", SBExceptionError(exception, @"listing displays").localizedDescription);
  }
  return screens;
}

@end

#pragma mark - SBScreen

@implementation SBScreen {
  id<SBSimScreen> _descriptor;
}

- (instancetype)initWithDescriptor:(id<SBSimScreen>)descriptor {
  self = [super init];
  if (self) {
    _descriptor = descriptor;
  }
  return self;
}

- (id<SBSimScreenProperties>)properties {
  return _descriptor.screenProperties;
}

- (uint32_t)screenID {
  return self.properties.screenID;
}

- (unsigned long long)screenType {
  return self.properties.screenType;
}

- (BOOL)poweredOn {
  return self.properties.powerState == 1;
}

- (NSInteger)backlightState {
  id<SBSimScreenBacklight> backlight = self.properties.backlight;
  return backlight ? backlight.state : -1;
}

- (CGSize)pixelSize {
  return self.properties.pixelSize;
}

- (double)scale {
  return self.properties.currentMode.preferredUIScale;
}

- (nullable IOSurface *)framebuffer {
  return _descriptor.framebufferSurface;
}

- (uint32_t)framebufferID {
  IOSurface *surface = _descriptor.framebufferSurface;
  return surface ? IOSurfaceGetID((__bridge IOSurfaceRef)surface) : 0;
}

- (NSUUID *)addFrameObserverOnQueue:(dispatch_queue_t)queue
                              frame:(void (^)(void))frame
                    surfacesChanged:(void (^)(void))surfacesChanged {
  NSUUID *token = [NSUUID UUID];
  @try {
    [_descriptor registerScreenCallbacksWithUUID:token
                                   callbackQueue:queue
                                   frameCallback:frame
                         surfacesChangedCallback:^(IOSurface *_Nullable a, IOSurface *_Nullable b) {
                           surfacesChanged();
                         }
                       propertiesChangedCallback:^(id properties) {
                         surfacesChanged();
                       }];
  } @catch (NSException *exception) {
    // No frames will arrive, which the settle monitor reports and recovers from.
    NSLog(@"glovebox: %@", SBExceptionError(exception, @"observing the display").localizedDescription);
  }
  return token;
}

- (void)removeFrameObserver:(NSUUID *)token {
  @try {
    [_descriptor unregisterScreenCallbacksWithUUID:token];
  } @catch (NSException *exception) {
    // The port is already gone, e.g. after a reboot; nothing is left to remove.
  }
}

@end

#pragma mark - Surface sampling

uint64_t SBSurfaceContentHash(IOSurface *surface) {
  size_t height = (size_t)surface.height;
  size_t rowBytes = (size_t)surface.width * (size_t)surface.bytesPerElement;
  size_t bytesPerRow = (size_t)surface.bytesPerRow;
  [surface lockWithOptions:kIOSurfaceLockReadOnly seed:NULL];
  const uint8_t *base = surface.baseAddress;
  // FNV-1a over 64-bit words: not cryptographic, but any changed pixel
  // changes it.
  uint64_t hash = 0xcbf29ce484222325ull ^ (uint64_t)surface.width << 32 ^ (uint64_t)height;
  for (size_t y = 0; y < height; y++) {
    const uint8_t *line = base + y * bytesPerRow;
    size_t x = 0;
    for (; x + 8 <= rowBytes; x += 8) {
      uint64_t word;
      memcpy(&word, line + x, 8);
      hash = (hash ^ word) * 0x100000001b3ull;
    }
    for (; x < rowBytes; x++) {
      hash = (hash ^ line[x]) * 0x100000001b3ull;
    }
  }
  [surface unlockWithOptions:kIOSurfaceLockReadOnly seed:NULL];
  return hash;
}

size_t SBSurfaceLuminanceGrid(IOSurface *surface, size_t cellSize, uint8_t *out, size_t capacity, size_t *columns,
                              size_t *rows) {
  if (surface.pixelFormat != 'BGRA' || cellSize == 0) {
    return 0;
  }
  size_t width = (size_t)surface.width;
  size_t height = (size_t)surface.height;
  size_t cols = width / cellSize;
  size_t rowCount = height / cellSize;
  if (cols == 0 || rowCount == 0 || cols * rowCount > capacity) {
    return 0;
  }
  [surface lockWithOptions:kIOSurfaceLockReadOnly seed:NULL];
  const uint8_t *base = surface.baseAddress;
  size_t bytesPerRow = (size_t)surface.bytesPerRow;
  // Sample a 4x4 lattice inside each cell: enough to see a cell change,
  // and cheap enough to run on every frame.
  size_t step = cellSize / 4 > 0 ? cellSize / 4 : 1;
  for (size_t row = 0; row < rowCount; row++) {
    for (size_t col = 0; col < cols; col++) {
      uint32_t sum = 0;
      uint32_t samples = 0;
      for (size_t y = row * cellSize + step / 2; y < (row + 1) * cellSize; y += step) {
        const uint8_t *line = base + y * bytesPerRow;
        for (size_t x = col * cellSize + step / 2; x < (col + 1) * cellSize; x += step) {
          const uint8_t *pixel = line + x * 4;  // B, G, R, A
          sum += (pixel[0] * 29u + pixel[1] * 150u + pixel[2] * 77u) >> 8;
          samples++;
        }
      }
      out[row * cols + col] = (uint8_t)(sum / (samples ? samples : 1));
    }
  }
  [surface unlockWithOptions:kIOSurfaceLockReadOnly seed:NULL];
  *columns = cols;
  *rows = rowCount;
  return cols * rowCount;
}
