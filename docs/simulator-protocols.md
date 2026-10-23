# Simulator protocols

The wire formats glovebox uses to reach Xcode 27's in-simulator daemons,
worked out from their error replies and code. [simulator-input.md](simulator-input.md)
covers the choices and measurements built on them.

## The `dtuhidd` protocol

Xcode 27's CoreDevice runs a HID daemon, `dtuhidd`, in each simulator; Device
Hub sends input through it. While it runs, backboardd's SimulatorHID
disconnects the Indigo keyboard, so glovebox's old Indigo keys did nothing.
`SBCoreDeviceHIDClient` (`Sources/SimBridgeObjC/SBCoreDeviceHIDClient.m`)
now sends keys and the hinge angle this way. Keys fall back to Indigo on a
simulator without `dtuhidd`. Found on 2026-10-18 from `dtuhidd`'s decoding
errors and Device Hub's `CoreDevicePopDeviceKitExtension`:

- **Connect.** `-[SimDevice lookup:error:]` with
  `com.apple.coredevice.feature.remote.hid.keyboard` (or `.button`,
  `.digitizer`, `.scroll`, `.vendordefined`) returns a mach port. Then
  `xpc_endpoint_create_mach_port_4sim(port)`,
  `xpc_connection_create_from_endpoint`, and
  `xpc_connection_enable_sim2host_4sim(connection)` before resuming. Without
  that last call, `dtuhidd` accepts the connection but drops every message
  without logging anything.
- **Messages** are XPC dictionaries:
  `{"messageType": "IndigoKeyboardButtonEvent", "payload": {...}}`. Device Hub
  also sends `featureIdentifier`, which `dtuhidd` ignores. An unknown
  `messageType` makes `dtuhidd` cancel the connection. Payload numbers are
  unsigned XPC integers.
- **Keep one connection open.** Each connection gets its own virtual HID
  devices (keyboard, buttons, three touchscreens, `avpCustom`). They appear
  about 0.7 s after the first message and go away when the connection closes.
  Events sent before the devices exist are lost. glovebox opens with a no-op
  message (`IndigoKeyboardConfigureEvent`, payload `{}`), waits for its reply,
  and reuses the connection.
- **Acknowledgments.** `dtuhidd` never replies, but a message sent with a
  reply handler gets `XPC_ERROR_CONNECTION_INTERRUPTED` once `dtuhidd` has
  handled it (within a few ms; about 0.7 s for the first message, once the
  devices exist). glovebox uses that as the acknowledgment.
- **Payloads:**
  - `IndigoKeyboardButtonEvent`: `{usageCode: UInt16 (HID usage), state:
    UInt8}`, where state 1 is down and 2 is up.
  - `IndigoButtonEvent`: `{usagePage, usageCode, state}`, sent to the
    `button` service: power is 0x0C/0x30 and home is 0x0C/0x40. glovebox sends
    every button this way; consumer 0xCF (Voice Command) does nothing, so
    Siri is a held power button.
  - `IndigoDigitizerEvent`: `{pointOne: {x, y: Double}, pointTwo (optional),
    eventType: 0 start / 1 position / 2 end, edge: 0 none, target}`. glovebox
    sends touches on foldables this way. From `dtuhidd`'s code: `target` N
    goes to the touchscreen `HIDServiceID.touchscreen(displayID: N)` (service
    ID 0x100 + N), and `dtuhidd` makes one per built-in display, so the
    target is the panel's screen ID (0 means the main screen, display 1).
    The Duo's inner panel is 3, which is why targets 0-2 earlier never
    reached it. `pointOne` is passed unscaled to
    `IOHIDEventCreateDigitizerFingerEvent`, so it is a 0-1 fraction of the
    panel's framebuffer (native orientation), the same ratio Indigo uses.
  - `IndigoVendorDefinedEvent` sets the hinge: `{usagePage: 0xFF61, usage:
    0x5B, version: 0, data}`, where `data` is `IOCFSerialize(dictionary,
    kIOCFSerializeToBinary)` of `{provider:
    "com.apple.Virtualization.VirtualMachines", source:
    "hinge-slider-control", type: "range", value: <degrees as a Double,
    0-180>}`. 90 makes SpringBoard log `90.0° ... partiallyOpen`; 0 closes
    the Duo onto its cover panel; 180 lays it flat.
- **Debugging.** Decoding errors show at error level in
  `log stream --predicate 'process == "dtuhidd"'` on the Mac. `dtuhidd`'s
  "Handling ..." lines are debug level and did not show. SpringBoard's
  `DisplayContentMode` category logs hinge changes.

### Touches on foldables

Indigo touches can't be used on a device with two built-in panels while
`dtuhidd` runs. On 2026-10-18 a tap on the open Duo's inner panel aborted
backboardd in `-[SimHIDVirtualService dispatchEvent:]` ("Unable to dispatch
event through disconnected service"), which restarted SpringBoard and ended
running apps (crash report `backboardd-2026-10-18-114655.ips`). From
SimulatorHID's code
(`CoreSimulator.framework/.../iphoneos/Library/Frameworks/SimulatorHID.framework`):

- While `dtuhidd` is active, `_locked_updateDTUHIDDAffectedServices`
  disconnects three Indigo services: the external keyboard, the main screen
  buttons and `builtInDigitizerService`.
- On an Indigo event, `ensureServiceActiveForIndigoHIDData:` reconnects the
  target's service only if it is one of those three, then dispatches, which
  asserts if the service is disconnected.
- `builtInDigitizerService` is one slot, so of the Duo's two built-in
  digitizers the one created first stays disconnected for good.

`dtuhidd`'s touchscreens belong to its connection and are always connected,
so glovebox sends foldables' touches there. Single-panel devices keep Indigo
touches, which are safe there.

## Interface rotation (`dtdeviceinfod`)

`dtdeviceinfod` serves CoreDevice's `getdisplayinfo` feature in each
simulator (`com.apple.coredevice.feature.getdisplayinfo`, reached like
`dtuhidd`'s services). `-[SBDevice interfaceRotationsWithError:]` in
`Sources/SimBridgeObjC/SBDisplayInfo.m` calls it. Worked out on 2026-10-18
from its error replies, which name each missing key:

- **Request**: a CoreDevice action invocation, sent with a reply:
  `CoreDevice.featureIdentifier` (the service name),
  `CoreDevice.actionIdentifier` (`com.apple.coredevice.action.displayinfo`),
  `CoreDevice.invocationIdentifier` (a UUID string),
  `CoreDevice.deviceIdentifier` (the UDID), `CoreDevice.coreDeviceVersion`
  (`{components: [UInt], originalComponentsCount: Int, stringValue}`),
  `CoreDevice.CoreDeviceDDIProtocolVersion` (Int, 0) and `CoreDevice.input`
  (`{}`). Integers must be signed or unsigned exactly as the Codable type
  wants (`Expected to decode Int but found a OS_xpc_uint64`).
- **Reply**: `CoreDevice.output` with `orientation` (the device's) and
  `displays`, each with `displayId` (the screen ID), `currentOrientation`
  (`rot0`, `rot90`, ...), `nativeOrientation`, `active`, `backlightState`,
  sizes and `uniqueId`. Errors come back as `CoreDevice.error`.
- The open Duo's inner panel (display 3) reports `rot90`: its 669x951
  framebuffer shows a 951x669 interface whose top runs along the
  framebuffer's left edge, so interface point (x, y) is framebuffer point
  (y, 951 - x). The closed Duo's cover panel reports `rot0`. A read takes
  about 2.5 ms and is cached with the display.
- `dthidd` serves `com.apple.coredevice.feature.remote.devicecontrol.orientation`
  (`{payload: {currentOrientation: {}}}` returns the device orientation);
  its `changeOrientation` request is a lead for a `rotate` tool.

