#import <xpc/xpc.h>

#import "PrivateAPI.h"
#import "SimBridgeObjC.h"

NS_ASSUME_NONNULL_BEGIN

NSError *SBError(SBErrorCode code, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

/// Converts an exception raised inside a private framework into an error, so
/// a framework that changed shape fails one call instead of the server.
/// `during` names the operation, e.g. "reading the accessibility tree".
NSError *SBExceptionError(NSException *exception, NSString *during);

/// Wraps `completion` so it runs at most once. Swift's async bridge crashes on
/// a second call, which a send that raises after scheduling it could cause.
void (^SBOnce(void (^completion)(NSError *_Nullable)))(NSError *_Nullable);

/// dlopens CoreSimulator, SimulatorKit and AccessibilityPlatformTranslation
/// once and resolves the Indigo builders. Safe to call repeatedly.
BOOL SBLoadFrameworks(NSError **error);

typedef struct {
  SBIndigoMouseFn _Nullable mouse;
  SBIndigoKeyboardFn _Nullable keyboard;
  SBIndigoButtonFn _Nullable button;
} SBIndigoFunctions;

/// Filled in by SBLoadFrameworks.
extern SBIndigoFunctions SBIndigo;

@interface SBDevice ()
@property (nonatomic, readonly) id<SBSimDevice> simDevice;
- (instancetype)initWithSimDevice:(id<SBSimDevice>)device;
@end

/// Opens and resumes a connection to the mach service `name` inside the
/// simulator, the way CoreSimulator reaches CoreDevice's daemons there
/// (dtuhidd, dtdeviceinfod). Fails with SBErrorHIDDaemonMissing when the
/// simulator has no such service.
xpc_connection_t _Nullable SBConnectToSimService(SBDevice *device, NSString *name, dispatch_queue_t queue,
                                                 void (^eventHandler)(xpc_object_t event), NSError **error);

@interface SBScreen ()
- (instancetype)initWithDescriptor:(id<SBSimScreen>)descriptor;
@end

NS_ASSUME_NONNULL_END
