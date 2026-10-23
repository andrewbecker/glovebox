# How glovebox's input reaches the simulator

Xcode 27 runs `dtuhidd`, CoreDevice's HID daemon, inside each simulator, and
Device Hub sends its input there. glovebox does the same, with SimulatorKit's
older Indigo path as the fallback for a simulator without `dtuhidd`. The wire
format is in [simulator-protocols.md](simulator-protocols.md); this page is
about the choices and the measurements behind them. Each number has a probe record in
[`probes/`](probes/).

## Which path each input takes

| Input | With `dtuhidd` | Without |
|---|---|---|
| Touches (tap, swipe, long press) | `IndigoDigitizerEvent` to the panel's touchscreen | Indigo touch messages |
| Keys | `IndigoKeyboardButtonEvent` | Indigo keyboard messages (dropped while `dtuhidd` runs) |
| Home, lock, side | `IndigoButtonEvent` (consumer page 0x0C: home 0x40, power 0x30) | Indigo button messages |
| Siri | power held for 1.5 s | Indigo Siri source |
| Apple Pay | power pressed twice, 150 ms apart | Indigo Apple Pay source |
| Hinge (foldables) | `IndigoVendorDefinedEvent`, swept in 45 steps | none |
| Shake | `notifyutil -p com.apple.UIKit.SimulatorShake` in the simulator, either way | |

Nothing goes through Indigo while `dtuhidd` runs:

- SimulatorHID disconnects Indigo's keyboard, buttons and built-in digitizer
  then, and an Indigo event for a disconnected service aborts backboardd.
- The Indigo Siri source crashed backboardd on Xcode 27.2 even on a
  single-panel iPhone ([probe](probes/2026-10-23-indigo-siri-crash.md)).

## Opening a connection

`dtuhidd` can be slow to start after a boot and exits when idle
(`EnablePressuredExit` in its launchd plist), so opening its service is
retried 5 times, 4 s apart. A missing daemon or framework is not retried. Each
connection's virtual devices appear about 0.7 s after its first message, so
glovebox opens with a no-op message and waits for its acknowledgment.

## Pacing

- **Swipes** make at least 20 moves, one every 8 ms through `dtuhidd` (17 ms
  through Indigo, which drops moves closer than 16 ms). Fewer moves made
  scroll views read a short swipe as a tap or a fling.
- **Keys**: arrow keys go 100 ms apart, since closer presses were dropped;
  other keys 10 ms apart.
- **Hinge**: 45 steps of 10 ms from the current angle, as a hand would move
  it. A single jump worked at first, but sweeps of 10 steps or fewer have
  wedged SpringBoard until a reboot.
- **Taps** hold for 50 ms: a SwiftUI switch ignores a touch whose down and up
  arrive together.

## Reading back

What glovebox touches comes from the accessibility tree (AXPTranslator). Content
another process draws (a web page, Safari's sheets, system alerts, the status
bar) is missing from that walk, but hit-testing a point finds it. So
`describe_ui`, and element queries that find nothing in the walk, also probe a
50-point grid over the parts of the screen the walk left uncovered
([probe](probes/2026-10-23-web-content-hit-test.md)).

## Settling

After an input, glovebox waits for the screen to go still. Taps use a 250 ms
quiet window; launches use 3.5 s, because cold launches pause over 2 s mid
transition ([probe](probes/2026-10-23-settle-cold-launch.md)).
