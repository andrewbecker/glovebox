// Display orientation from dtdeviceinfod, the device-info daemon Xcode 27's
// CoreDevice runs in each simulator. A panel can draw its interface rotated
// in its framebuffer: the open iPhone Duo's inner panel has a portrait
// framebuffer with a landscape interface ("rot90"). Accessibility frames are
// in the rotated interface space, while framebuffers and touch digitizers
// stay in the panel's native space.
//
// The protocol was worked out from dtdeviceinfod's error replies (Xcode 27).
// Requests are CoreDevice action invocations: an XPC dictionary of
// CoreDevice.* keys, each of which dtdeviceinfod names when it is missing,
// and whose Codable values are strict about signed and unsigned integers.
// The reply's CoreDevice.output has a `displays` array; each display has a
// `displayId` (the simulator's screen ID) and a `currentOrientation` such as
// "rot0" or "rot90".
#import "Internal.h"

static NSString *const SBDisplayInfoService = @"com.apple.coredevice.feature.getdisplayinfo";
static NSString *const SBDisplayInfoAction = @"com.apple.coredevice.action.displayinfo";
static const int64_t SBDisplayInfoTimeout = 2 * NSEC_PER_SEC;

/// The CoreDevice version the Mac has installed, which is the one Device Hub
/// sends. dtdeviceinfod requires one.
static NSString *SBCoreDeviceVersion(void) {
  static NSString *version;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSBundle *bundle = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"];
    version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"651.13.5";
  });
  return version;
}

static xpc_object_t SBVersionObject(NSString *version) {
  NSArray<NSString *> *parts = [version componentsSeparatedByString:@"."];
  xpc_object_t components = xpc_array_create(NULL, 0);
  for (NSString *part in parts) {
    xpc_array_set_uint64(components, XPC_ARRAY_APPEND, (uint64_t)part.longLongValue);
  }
  xpc_object_t object = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_value(object, "components", components);
  xpc_dictionary_set_int64(object, "originalComponentsCount", (int64_t)parts.count);
  xpc_dictionary_set_string(object, "stringValue", version.UTF8String);
  return object;
}

@implementation SBDevice (DisplayInfo)

- (nullable NSDictionary<NSNumber *, NSNumber *> *)interfaceRotationsWithError:(NSError **)error {
  dispatch_queue_t queue = dispatch_queue_create("glovebox.displayinfo", DISPATCH_QUEUE_SERIAL);
  xpc_connection_t connection = SBConnectToSimService(self, SBDisplayInfoService, queue, ^(xpc_object_t event) {}, error);
  if (!connection) {
    return nil;
  }
  xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(message, "CoreDevice.featureIdentifier", SBDisplayInfoService.UTF8String);
  xpc_dictionary_set_string(message, "CoreDevice.actionIdentifier", SBDisplayInfoAction.UTF8String);
  xpc_dictionary_set_string(message, "CoreDevice.invocationIdentifier", NSUUID.UUID.UUIDString.UTF8String);
  xpc_dictionary_set_string(message, "CoreDevice.deviceIdentifier", self.udid.UTF8String);
  xpc_dictionary_set_value(message, "CoreDevice.coreDeviceVersion", SBVersionObject(SBCoreDeviceVersion()));
  xpc_dictionary_set_int64(message, "CoreDevice.CoreDeviceDDIProtocolVersion", 0);
  xpc_dictionary_set_value(message, "CoreDevice.input", xpc_dictionary_create(NULL, NULL, 0));

  dispatch_semaphore_t answered = dispatch_semaphore_create(0);
  __block xpc_object_t reply = nil;
  xpc_connection_send_message_with_reply(connection, message, queue, ^(xpc_object_t object) {
    reply = object;
    dispatch_semaphore_signal(answered);
  });
  BOOL timedOut = dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, SBDisplayInfoTimeout)) != 0;
  xpc_connection_cancel(connection);
  if (timedOut) {
    if (error) {
      *error = SBError(SBErrorNotResponding, @"The simulator's device-info daemon (dtdeviceinfod) did not answer within 2 s.");
    }
    return nil;
  }
  // The reply block has run, so reading `reply` races with nothing.
  xpc_object_t output = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(reply, "CoreDevice.output") : nil;
  xpc_object_t displays = output ? xpc_dictionary_get_array(output, "displays") : nil;
  if (!displays) {
    if (error) {
      char *description = xpc_copy_description(reply);
      *error = SBError(SBErrorUnsupported, @"Unexpected display info from dtdeviceinfod: %s", description);
      free(description);
    }
    return nil;
  }
  NSMutableDictionary<NSNumber *, NSNumber *> *rotations = [NSMutableDictionary dictionary];
  xpc_array_apply(displays, ^bool(size_t index, xpc_object_t display) {
    const char *orientation = xpc_get_type(display) == XPC_TYPE_DICTIONARY
                                  ? xpc_dictionary_get_string(display, "currentOrientation")
                                  : NULL;
    if (orientation && strncmp(orientation, "rot", 3) == 0) {
      rotations[@(xpc_dictionary_get_uint64(display, "displayId"))] = @(atoi(orientation + 3));
    }
    return true;
  });
  return rotations;
}

@end
