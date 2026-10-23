# Indigo Siri crash

**Setup.** Xcode 27.2, an iPhone 18 Pro on iOS 27.2 with `dtuhidd` running.

**Run.** `press_button {"button": "siri"}` sent through Indigo
(`IndigoHIDMessageForButton` with source 0x400002).

**Result.** backboardd crashed twice, with SIGBUS in
`IOHIDEventCreateVendorDefinedEvent` called from SimulatorHID's
`-[SimHIDSystem initUsingHIDService:]` (crash report
`backboardd-2026-10-23-070942.ips`). SpringBoard restarted; the device
recovered by itself, but the server process that sent it kept reporting "no
framebuffer" until it was restarted.

Consumer usage 0xCF (Voice Command) through `dtuhidd`'s button service did
nothing.

**Decision.** Siri is the power button held for 1.5 s through `dtuhidd`
(the Siri orb appeared). No button goes through Indigo while `dtuhidd` runs.
