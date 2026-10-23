// Input through dtuhidd, the HID daemon that Xcode 27's CoreDevice runs in
// each simulator. Device Hub types and moves a foldable's hinge this way.
// While dtuhidd runs, backboardd's SimulatorHID disconnects the Indigo
// keyboard, so keys sent through SBHIDClient are ignored.
//
// The protocol was worked out from dtuhidd's decoding errors and from Device
// Hub's CoreDevicePopDeviceKitExtension (Xcode 27):
// - dtuhidd listens on com.apple.coredevice.feature.remote.hid.* in the
//   simulator's bootstrap, and -[SimDevice lookup:error:] returns the port.
// - The connection needs xpc_connection_enable_sim2host_4sim, as dtuhidd's
//   listener has. Without it dtuhidd drops every message without a word.
// - Messages are {"messageType": <event type>, "payload": <event fields>},
//   with unsigned integers. An unknown type makes dtuhidd cancel the
//   connection.
// - Each connection gets its own virtual HID devices about 0.7 s after its
//   first message and loses them when it closes. Events sent before they
//   exist are lost, so a connection opens with a no-op event and is kept.
// - dtuhidd never replies. A message sent with a reply anyway comes back as
//   XPC_ERROR_CONNECTION_INTERRUPTED once dtuhidd has handled and released
//   it, which serves as an acknowledgment.
#import <IOKit/IOCFSerialize.h>
#import <dlfcn.h>
#import <xpc/xpc.h>

#import "Internal.h"

static NSString *const SBHIDServicePrefix = @"com.apple.coredevice.feature.remote.hid.";
static const int64_t SBHIDOpenTimeout = 5 * NSEC_PER_SEC;
/// launchd throttles a job that exits within its 10 s minimum runtime, so a
/// dtuhidd that crashed early in boot refuses connections for a while. An
/// open is retried this many times, this far apart.
static const int SBHIDOpenAttempts = 5;
static const int64_t SBHIDOpenRetryDelay = 4 * NSEC_PER_SEC;
static const int64_t SBHIDSendTimeout = 5 * NSEC_PER_SEC;
static const uint64_t SBHIDStateDown = 1;
static const uint64_t SBHIDStateUp = 2;
static const uint64_t SBDigitizerStart = 0;
static const uint64_t SBDigitizerPosition = 1;
static const uint64_t SBDigitizerEnd = 2;

// libxpc functions CoreSimulator uses to reach services inside a simulator.
typedef xpc_endpoint_t _Nullable (*SBEndpointFromPortFn)(mach_port_t port);
typedef void (*SBEnableSim2HostFn)(xpc_connection_t connection);

static SBEndpointFromPortFn SBEndpointFromPort;
static SBEnableSim2HostFn SBEnableSim2Host;

static BOOL SBLoadXPCFunctions(NSError **error) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    SBEndpointFromPort = (SBEndpointFromPortFn)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    SBEnableSim2Host = (SBEnableSim2HostFn)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
  });
  if (SBEndpointFromPort && SBEnableSim2Host) {
    return YES;
  }
  if (error) {
    *error = SBError(SBErrorFrameworkMissing, @"libxpc is missing the functions for reaching simulator services.");
  }
  return NO;
}

xpc_connection_t _Nullable SBConnectToSimService(SBDevice *device, NSString *name, dispatch_queue_t queue,
                                                 void (^eventHandler)(xpc_object_t event), NSError **error) {
  if (!SBLoadXPCFunctions(error)) {
    return nil;
  }
  id<SBSimDevice> simDevice = device.simDevice;
  if (![simDevice respondsToSelector:@selector(lookup:error:)]) {
    if (error) {
      *error = SBError(SBErrorHIDDaemonMissing, @"This CoreSimulator cannot look up services inside a simulator.");
    }
    return nil;
  }
  NSError *lookupError = nil;
  mach_port_t port = MACH_PORT_NULL;
  @try {
    port = [simDevice lookup:name error:&lookupError];
  } @catch (NSException *exception) {
    if (error) {
      *error = SBExceptionError(exception, [NSString stringWithFormat:@"looking up %@", name]);
    }
    return nil;
  }
  if (port == MACH_PORT_NULL) {
    if (error) {
      *error = SBError(SBErrorHIDDaemonMissing, @"The simulator has no %@: %@", name,
                       lookupError.localizedDescription ?: @"no service");
    }
    return nil;
  }
  // The send right from the lookup stays with the endpoint; one per
  // connection is leaked if the endpoint keeps its own.
  xpc_endpoint_t endpoint = SBEndpointFromPort(port);
  if (!endpoint) {
    if (error) {
      *error = SBError(SBErrorUnsupported, @"Could not make an XPC endpoint for %@.", name);
    }
    return nil;
  }
  xpc_connection_t connection = xpc_connection_create_from_endpoint(endpoint);
  SBEnableSim2Host(connection);
  xpc_connection_set_target_queue(connection, queue);
  xpc_connection_set_event_handler(connection, eventHandler);
  xpc_connection_resume(connection);
  return connection;
}

static xpc_object_t SBHIDMessage(const char *type, xpc_object_t payload) {
  xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(message, "messageType", type);
  xpc_dictionary_set_value(message, "payload", payload);
  return message;
}

@implementation SBCoreDeviceHIDClient {
  SBDevice *_device;
  dispatch_queue_t _queue;
  /// Open connections by service suffix (e.g. "keyboard"). Only used on _queue.
  NSMutableDictionary<NSString *, xpc_connection_t> *_connections;
}

- (instancetype)initWithDevice:(SBDevice *)device {
  self = [super init];
  if (self) {
    _device = device;
    _queue = dispatch_queue_create("glovebox.dtuhidd", DISPATCH_QUEUE_SERIAL);
    _connections = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)dealloc {
  // Closing a connection makes dtuhidd remove its virtual HID devices.
  for (xpc_connection_t connection in _connections.allValues) {
    xpc_connection_cancel(connection);
  }
}

- (BOOL)isDaemonRunning {
  id<SBSimDevice> simDevice = _device.simDevice;
  if (![simDevice respondsToSelector:@selector(lookup:error:)]) {
    return NO;
  }
  mach_port_t port = MACH_PORT_NULL;
  @try {
    port = [simDevice lookup:[SBHIDServicePrefix stringByAppendingString:@"keyboard"] error:NULL];
  } @catch (NSException *exception) {
    return NO;
  }
  if (port == MACH_PORT_NULL) {
    return NO;
  }
  mach_port_deallocate(mach_task_self(), port);
  return YES;
}

- (void)sendKeyUsage:(uint16_t)usage down:(BOOL)down completion:(void (^)(NSError *_Nullable))completion {
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usageCode", usage);
  xpc_dictionary_set_uint64(payload, "state", down ? SBHIDStateDown : SBHIDStateUp);
  [self send:"IndigoKeyboardButtonEvent" payload:payload service:@"keyboard" completion:completion];
}

- (void)sendTouchPhase:(SBTouchPhase)phase
                 ratio:(CGPoint)ratio
               display:(uint32_t)displayID
            completion:(void (^)(NSError *_Nullable))completion {
  // dtuhidd hands the point unscaled to IOHIDEventCreateDigitizerFingerEvent,
  // whose display-integrated coordinates are fractions of the panel.
  xpc_object_t point = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_double(point, "x", ratio.x);
  xpc_dictionary_set_double(point, "y", ratio.y);
  uint64_t eventType = phase == SBTouchPhaseDown ? SBDigitizerStart : phase == SBTouchPhaseUp ? SBDigitizerEnd : SBDigitizerPosition;
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_value(payload, "pointOne", point);
  xpc_dictionary_set_uint64(payload, "eventType", eventType);
  xpc_dictionary_set_uint64(payload, "edge", 0);
  // dtuhidd sends target N to the touchscreen it made for display N (0 is
  // the main screen, display 1), one per built-in display.
  xpc_dictionary_set_uint64(payload, "target", displayID);
  [self send:"IndigoDigitizerEvent" payload:payload service:@"digitizer" completion:completion];
}

- (void)sendButtonUsagePage:(uint16_t)usagePage
                      usage:(uint16_t)usage
                       down:(BOOL)down
                 completion:(void (^)(NSError *_Nullable))completion {
  // dtuhidd sends these to its "main screen button" service.
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usagePage", usagePage);
  xpc_dictionary_set_uint64(payload, "usageCode", usage);
  xpc_dictionary_set_uint64(payload, "state", down ? SBHIDStateDown : SBHIDStateUp);
  [self send:"IndigoButtonEvent" payload:payload service:@"button" completion:completion];
}

- (void)sendHingeAngle:(double)degrees completion:(void (^)(NSError *_Nullable))completion {
  // The dictionary Device Hub's hinge slider sends, serialized the same way.
  NSDictionary *state = @{
    @"provider": @"com.apple.Virtualization.VirtualMachines",
    @"source": @"hinge-slider-control",
    @"type": @"range",
    @"value": @(MIN(MAX(degrees, 0), 180)),
  };
  CFDataRef data = IOCFSerialize((__bridge CFTypeRef)state, kIOCFSerializeToBinary);
  if (!data) {
    completion(SBError(SBErrorUnsupported, @"Could not encode the hinge angle."));
    return;
  }
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usagePage", 0xFF61);
  xpc_dictionary_set_uint64(payload, "usage", 0x5B);
  xpc_dictionary_set_uint64(payload, "version", 0);
  xpc_dictionary_set_data(payload, "data", CFDataGetBytePtr(data), (size_t)CFDataGetLength(data));
  CFRelease(data);
  [self send:"IndigoVendorDefinedEvent" payload:payload service:@"vendordefined" completion:completion];
}

- (void)send:(const char *)type
     payload:(xpc_object_t)payload
     service:(NSString *)service
  completion:(void (^)(NSError *_Nullable))completion {
  completion = SBOnce(completion);
  xpc_object_t message = SBHIDMessage(type, payload);
  dispatch_async(_queue, ^{
    NSError *error = nil;
    xpc_connection_t connection = [self connectionForService:service error:&error];
    if (!connection) {
      completion(error);
      return;
    }
    // Both handlers run on _queue, so the flag needs no lock.
    __block BOOL answered = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SBHIDSendTimeout), self->_queue, ^{
      if (answered) {
        return;
      }
      [self dropConnection:connection service:service];
      completion(SBError(SBErrorNotResponding, @"The simulator's HID daemon (dtuhidd) did not take the input within 5 s."));
    });
    xpc_connection_send_message_with_reply(connection, message, self->_queue, ^(xpc_object_t reply) {
      answered = YES;
      if (reply == XPC_ERROR_CONNECTION_INVALID) {
        [self dropConnection:connection service:service];
        completion(SBError(SBErrorDeviceNotFound, @"The connection to the simulator's HID daemon (dtuhidd) closed."));
        return;
      }
      // Interrupted means dtuhidd handled the message without replying.
      completion(nil);
    });
  });
}

/// The open connection to dtuhidd's `service`, opened first if needed. Runs
/// on _queue and blocks it while a connection opens, so events queue behind
/// the opening instead of reaching dtuhidd before its devices exist. An open
/// that dtuhidd refuses or never answers is retried, since launchd may be
/// holding back a dtuhidd that crashed early in boot.
- (nullable xpc_connection_t)connectionForService:(NSString *)service error:(NSError **)error {
  xpc_connection_t existing = _connections[service];
  if (existing) {
    return existing;
  }
  NSError *lastError = nil;
  for (int attempt = 1; attempt <= SBHIDOpenAttempts; attempt++) {
    if (attempt > 1) {
      [NSThread sleepForTimeInterval:(double)SBHIDOpenRetryDelay / NSEC_PER_SEC];
    }
    lastError = nil;
    xpc_connection_t connection = [self openConnectionForService:service error:&lastError];
    if (connection) {
      _connections[service] = connection;
      return connection;
    }
    // No dtuhidd at all (an older simulator) is not worth waiting for.
    if (lastError.code == SBErrorHIDDaemonMissing || lastError.code == SBErrorFrameworkMissing ||
        lastError.code == SBErrorUnsupported) {
      break;
    }
  }
  if (error) {
    *error = lastError;
  }
  return nil;
}

/// One attempt at opening a connection to dtuhidd's `service`.
- (nullable xpc_connection_t)openConnectionForService:(NSString *)service error:(NSError **)error {
  NSString *name = [SBHIDServicePrefix stringByAppendingString:service];
  __weak SBCoreDeviceHIDClient *weakSelf = self;
  // Set once the connection exists. The handler runs on _queue, which this
  // method holds until then. Cancelling the connection breaks the cycle.
  __block xpc_connection_t live = nil;
  xpc_connection_t connection = SBConnectToSimService(_device, name, _queue, ^(xpc_object_t event) {
    // Any error means dtuhidd's devices for this connection are gone (for
    // example after it restarted or exited while idle), so the next event
    // opens a new one.
    if (xpc_get_type(event) == XPC_TYPE_ERROR && live) {
      [weakSelf dropConnection:live service:service];
    }
  }, error);
  if (!connection) {
    return nil;
  }
  live = connection;

  // Open with a no-op event and wait until dtuhidd has handled it, by which
  // time this connection's virtual devices exist. This is the liveness
  // check: a dtuhidd that died leaves a port that still resolves and takes
  // every message, but never handles one.
  dispatch_semaphore_t opened = dispatch_semaphore_create(0);
  __block BOOL closed = NO;
  xpc_object_t opener = SBHIDMessage("IndigoKeyboardConfigureEvent", xpc_dictionary_create(NULL, NULL, 0));
  xpc_connection_send_message_with_reply(connection, opener, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                                         ^(xpc_object_t reply) {
                                           closed = reply == XPC_ERROR_CONNECTION_INVALID;
                                           dispatch_semaphore_signal(opened);
                                         });
  BOOL timedOut = dispatch_semaphore_wait(opened, dispatch_time(DISPATCH_TIME_NOW, SBHIDOpenTimeout)) != 0;
  if (timedOut || closed) {
    xpc_connection_cancel(connection);
    if (error) {
      *error = timedOut ? SBError(SBErrorNotResponding, @"The simulator's HID daemon (dtuhidd) did not answer within 5 s.")
                        : SBError(SBErrorDeviceNotFound, @"The simulator's HID daemon (dtuhidd) closed the connection.");
    }
    return nil;
  }
  return connection;
}

/// Forgets `connection` if it is still the open one for `service`. Runs on _queue.
- (void)dropConnection:(xpc_connection_t)connection service:(NSString *)service {
  if (_connections[service] == connection) {
    [_connections removeObjectForKey:service];
    xpc_connection_cancel(connection);
  }
}

@end
