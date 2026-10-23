# Probes

A probe is a measurement on a real simulator that a constant or a rule in
glovebox rests on. Each record says what was run, on what, and what came out, so
a later Xcode can be checked by running it again. Before changing a constant,
run its probe on every iOS runtime in use.

| Probe | Backs |
|---|---|
| [Settle on cold launches](2026-10-23-settle-cold-launch.md) | `DeviceSession.launchQuiet` (3.5 s) |
| [Indigo Siri crash](2026-10-23-indigo-siri-crash.md) | Siri as a held power button; no Indigo while `dtuhidd` runs |
| [Web content by hit-testing](2026-10-23-web-content-hit-test.md) | `HitTestGrid`, `include_web` |
| [Launch under a system alert](2026-10-23-launch-under-alert.md) | `waitUntilFrontmostOrAlert` |
| [Debugging through lldb-dap](2026-10-23-lldb-dap.md) | `DAPClient`, `Debugger` |
| [Frames on a rotated panel, and grid cost](2026-10-23-rotated-frames.md) | `interfaceOriented`, `normalizedHit`, the grid's skipping |
