// Objective-C bridge over Apple's private simulator frameworks, which are
// loaded at runtime. Class and selector shapes are derived from facebook/idb
// (MIT) and verified against Xcode 27 with nm, otool and the ObjC runtime.
// Only thin wrappers live here; behavior is implemented in the SimBridge
// Swift target.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SBErrorDomain;

/// Returns the active developer directory, looked up as xcrun does:
/// $DEVELOPER_DIR, then /var/db/xcode_select_link, then `xcode-select -p`.
NSString *_Nullable SBDeveloperDirectory(void);

/// CoreSimulator's CFBundleVersion, e.g. "1174.20". From 1155.4 on, the
/// guest keyboard belongs to dtuhidd and Indigo keys are dropped.
NSString *_Nullable SBCoreSimulatorVersion(void);

@class SBScreen;

/// A booted (or bootable) simulator from CoreSimulator's default device set.
NS_SWIFT_SENDABLE
@interface SBDevice : NSObject
+ (nullable instancetype)deviceWithUDID:(NSString *)udid error:(NSError **)error;
@property (nonatomic, readonly) NSString *udid;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) BOOL isBooted;
/// When the simulator last booted, so it changes on every boot. Nil if this
/// CoreSimulator does not report it.
@property (nonatomic, readonly, nullable) NSDate *lastBootedAt;
/// Display ports that render a framebuffer. Foldable devices have several.
- (NSArray<SBScreen *> *)screens;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SBDevice (DisplayInfo)
/// Each display's interface rotation in its framebuffer, by screen ID, in
/// degrees as dtdeviceinfod reports it ("rot90" is 90). With 90, the
/// interface's top runs along the framebuffer's left edge. Fails with
/// SBErrorHIDDaemonMissing on simulators without dtdeviceinfod (before
/// Xcode 27). Blocks for one round trip, at most 2 s.
- (nullable NSDictionary<NSNumber *, NSNumber *> *)interfaceRotationsWithError:(NSError **)error;
@end

/// One display of a simulator. Property reads go to the simulator over XPC,
/// so they always reflect the current state.
NS_SWIFT_SENDABLE
@interface SBScreen : NSObject
@property (nonatomic, readonly) uint32_t screenID;
/// 0 for built-in panels; 1 and 2 are TV-out and wireless displays.
@property (nonatomic, readonly) unsigned long long screenType;
@property (nonatomic, readonly) BOOL poweredOn;
/// Positive while the panel is lit. Negative when the panel has no backlight
/// state, e.g. the folded-away panel of a foldable.
@property (nonatomic, readonly) NSInteger backlightState;
@property (nonatomic, readonly) CGSize pixelSize;
/// Pixels per point for the current mode, or 0 if unknown.
@property (nonatomic, readonly) double scale;
@property (nonatomic, readonly, nullable) IOSurface *framebuffer;
/// IOSurface ID of the current framebuffer, or 0. Changes when the surface is
/// replaced (e.g. on resize), not when its contents are redrawn.
@property (nonatomic, readonly) uint32_t framebufferID;

/// Calls `frame` once per rendered frame and `surfacesChanged` when the
/// framebuffer surface is replaced. Returns a token for removeFrameObserver:.
- (NSUUID *)addFrameObserverOnQueue:(dispatch_queue_t)queue
                              frame:(void (^)(void))frame
                    surfacesChanged:(void (^)(void))surfacesChanged;
- (void)removeFrameObserver:(NSUUID *)token;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef NS_ENUM(NSUInteger, SBTouchPhase) {
  SBTouchPhaseDown = 1,  // NSEventTypeLeftMouseDown
  SBTouchPhaseUp = 2,    // NSEventTypeLeftMouseUp
  SBTouchPhaseMove = 6,  // NSEventTypeLeftMouseDragged
};

/// Sends Indigo HID messages (touch, keyboard, hardware buttons) in-process.
NS_SWIFT_SENDABLE
@interface SBHIDClient : NSObject
- (nullable instancetype)initWithDevice:(SBDevice *)device error:(NSError **)error;
/// `ratio` is the touch location as a fraction of the display (0...1).
/// Fails with SBErrorThrottled when SimulatorKit drops a move that follows the
/// previous event too closely (under 16 ms).
- (void)sendTouchPhase:(SBTouchPhase)phase
                 ratio:(CGPoint)ratio
                target:(uint32_t)target
            completion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(sendTouch(_:ratio:target:completion:));
/// `usage` is a USB HID usage on the keyboard page (0x07).
- (void)sendKeyUsage:(uint32_t)usage down:(BOOL)down completion:(void (^)(NSError *_Nullable error))completion;
- (void)sendButtonSource:(uint32_t)source
                    down:(BOOL)down
                  target:(uint32_t)target
              completion:(void (^)(NSError *_Nullable error))completion;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Sends input through dtuhidd, the HID daemon Xcode 27's CoreDevice runs in
/// each simulator, the way Device Hub does. Keys must go this way while
/// dtuhidd runs. Fails with SBErrorHIDDaemonMissing when the simulator has no
/// dtuhidd (older Xcode), where SBHIDClient's keys still work.
NS_SWIFT_SENDABLE
@interface SBCoreDeviceHIDClient : NSObject
- (instancetype)initWithDevice:(SBDevice *)device;
/// Whether the simulator runs dtuhidd, checked by looking up its services.
@property(nonatomic, readonly, getter=isDaemonRunning) BOOL daemonRunning;
/// `usage` is a USB HID usage on the keyboard page (0x07).
- (void)sendKeyUsage:(uint16_t)usage down:(BOOL)down completion:(void (^)(NSError *_Nullable error))completion;
/// `ratio` is the touch location as a fraction of the panel (0...1), and
/// `displayID` the panel's screen ID.
- (void)sendTouchPhase:(SBTouchPhase)phase
                 ratio:(CGPoint)ratio
               display:(uint32_t)displayID
            completion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(sendTouch(_:ratio:display:completion:));
/// Presses or releases a hardware button by HID usage, e.g. Consumer (0x0C)
/// Menu (0x40) for home and Power (0x30) for the side button.
- (void)sendButtonUsagePage:(uint16_t)usagePage
                      usage:(uint16_t)usage
                       down:(BOOL)down
                 completion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(sendButton(usagePage:usage:down:completion:));
/// Sets a foldable's hinge, in degrees from 0 (closed) to 180 (open flat).
- (void)sendHingeAngle:(double)degrees completion:(void (^)(NSError *_Nullable error))completion;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef NS_ERROR_ENUM(SBErrorDomain, SBErrorCode) {
  SBErrorFrameworkMissing = 1,
  SBErrorDeviceNotFound,
  SBErrorUnsupported,
  SBErrorThrottled,
  SBErrorAccessibility,
  /// The app did not answer an accessibility request in time.
  SBErrorNotResponding,
  /// A private framework raised an Objective-C exception.
  SBErrorException,
  /// The simulator has no dtuhidd to send input through.
  SBErrorHIDDaemonMissing,
  /// The app answered with an empty tree at once, as on its launch screen,
  /// or there is no frontmost app yet.
  SBErrorNotReady,
};

/// Reads the accessibility tree of the frontmost app through
/// AccessibilityPlatformTranslation. Results are JSON objects with the keys
/// role, label, value, identifier, placeholder, frame [x, y, w, h] in points,
/// enabled and children; the root of a tree also has the app's pid.
NS_SWIFT_SENDABLE
@interface SBAccessibility : NSObject
- (instancetype)initWithDevice:(SBDevice *)device;
- (void)frontmostTreeWithMaxElements:(NSInteger)maxElements
                          completion:(void (^)(NSData *_Nullable json, NSError *_Nullable error))completion;
/// Process ID of the frontmost application (SpringBoard on the home screen).
- (void)frontmostApplicationPIDWithCompletion:(void (^)(NSInteger pid, NSError *_Nullable error))completion;
/// The deepest element at `point`, without children. `point` is in points
/// in the panel's framebuffer orientation (AXPTranslator hit-tests before
/// the interface rotation, though it reports frames after it), and
/// `displayID` is the panel's screen ID: 0 finds nothing on the open iPhone
/// Duo's inner panel (screen 3). `shownPoint` is the interface point, for
/// the error message.
- (void)elementAtPoint:(CGPoint)point
             displayID:(uint32_t)displayID
            shownPoint:(CGPoint)shownPoint
            completion:(void (^)(NSData *_Nullable json, NSError *_Nullable error))completion;
/// The deepest element at each of `points` (as for elementAtPoint), as a
/// JSON array with one entry per distinct element, in the order first hit,
/// each with `at`, the shown point it was first hit at.
/// Points where nothing answers are skipped. `shownPoints` are the same
/// points in interface coordinates: a point inside a leaf an earlier point
/// hit (any role but `containerRoles`, with text or an identifier) is not
/// asked again, since it would find the same element. Stops early after
/// `timeLimit` seconds.
- (void)elementsAtPoints:(NSArray<NSValue *> *)points
             shownPoints:(NSArray<NSValue *> *)shownPoints
               displayID:(uint32_t)displayID
          containerRoles:(NSSet<NSString *> *)containerRoles
               timeLimit:(NSTimeInterval)timeLimit
              completion:(void (^)(NSData *_Nullable json, NSError *_Nullable error))completion;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Writes a coarse luminance grid of `surface` into `out` (one byte per cell of
/// `cellSize` x `cellSize` pixels, row-major). Returns the number of cells
/// written, or 0 if the surface is not 32-bit BGRA or `capacity` is too small.
/// Used to tell real screen changes from caret blinks without decoding images.
size_t SBSurfaceLuminanceGrid(IOSurface *surface, size_t cellSize, uint8_t *out, size_t capacity,
                              size_t *columns, size_t *rows);

/// A hash of every visible pixel of `surface` (row padding excluded): equal
/// hashes mean the screen shows exactly the same image. About 3 ms for a
/// 22 MB framebuffer.
uint64_t SBSurfaceContentHash(IOSurface *surface);

NS_ASSUME_NONNULL_END
