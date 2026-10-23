# glovebox

An MCP server that lets an agent drive iOS Simulators: see the screen, read the
UI hierarchy, tap, swipe, type, press buttons and manage apps. Like
[facebook/idb](https://github.com/facebook/idb), it talks to Apple's private
simulator frameworks in-process instead of spawning a process per action, so a
tap costs about a millisecond.

glovebox does not build apps. Build with the Xcode MCP server, then hand the `.app`
to glovebox's `install_app` and `launch_app`.

## Requirements

- macOS 14 or later on Apple silicon
- Xcode 27 (verified with Xcode 27.2 and iOS 26.5, 27.1 and 27.2 simulators), selected with `xcode-select` or `DEVELOPER_DIR`

The private frameworks are loaded at runtime from the selected Xcode, so the
binary keeps working when Xcode moves. A new Xcode can change those APIs; glovebox
reports a clear error instead of crashing when something is missing.

## Install

```sh
git clone https://github.com/andrewbecker/glovebox.git
cd glovebox
scripts/install-local.sh --register
```

The script builds a release binary, installs `glovebox-mcp` and a `glovebox`
link to it in `~/.local/bin` (`PREFIX` changes that), and registers the server
with Claude Code at user scope. Without `--register` it prints the command
instead. Any other MCP client can run `~/.local/bin/glovebox-mcp` over stdio;
it takes no arguments.

To run it from the build folder instead:

```sh
swift build -c release
claude mcp add glovebox -- "$PWD/.build/release/glovebox-mcp"
```

### As a Claude Code plugin

The repo is also a plugin marketplace. The plugin registers the installed
`~/.local/bin/glovebox-mcp` and adds a usage skill (`skills/glovebox-usage`)
that teaches the agent the tools. Install the binary first, then:

```
/plugin marketplace add andrewbecker/glovebox
/plugin install glovebox@glovebox
```

Use the plugin or `--register`, not both, or the client starts two servers.

Simulators can run headless. To watch one, use Xcode's Device Hub (Xcode 27
has no Simulator.app). `boot` opens Device Hub by default; pass
`"open_device_hub": false` to skip it.

Run the unit tests with `swift test`. They need no simulator. See
[Testing](#testing) for the rest.

`TestApp/` is a small SwiftUI app for trying glovebox end to end: a form, a
button that blocks the main thread for 2 s, and loading spinners.
`TestApp/build.sh` builds it with `swiftc` (no Xcode project) and prints the
`.app` path for `install_app`; its bundle ID is `dev.glovebox.TestApp`. It is
built unoptimized with debug info, so `debug_attach` can stop it at a line
(Submit's action is `TestApp.swift:35`).

## Tools

| Group | Tools |
|---|---|
| Devices | `list_devices`, `boot`, `shutdown`, `erase`, `open_url`, `set_appearance` |
| Apps | `install_app`, `launch_app`, `terminate_app`, `uninstall_app`, `list_apps` |
| Observe | `screenshot`, `describe_ui`, `describe_point`, `find_elements`, `wait_for` |
| Interact | `tap`, `long_press`, `swipe`, `scroll_to`, `press_button`, `shake`, `fold` |
| Keyboard | `type_text`, `press_key`, `key_chord`, `hold_key`, `clear_text` |
| Diagnostics | `get_logs` |
| Debugging (opt-in) | `debug_attach`, `debug_breakpoint`, `debug_wait`, `debug_evaluate`, `debug_continue`, `debug_detach` |
| Batch | `batch` |

Every tool takes an optional `udid`. It defaults to the last device used, or to
the only booted simulator.

### Coordinates

Everything is in points, the space accessibility frames use. A screenshot at
the default `scale` of 1 has one pixel per point, so a position read off the
image can be tapped directly. `tap`, `long_press`, `type_text` and `clear_text`
also accept an element query instead of coordinates and act where VoiceOver
would: the match's activation point, which is its center except on controls
such as a switch row, where it is the switch itself:

```json
{"label": "General"}
{"identifier": "loginButton"}
{"role": "TextField", "text_match": "email"}
{"label_contains": "Sign", "index": 1}
```

String matches are case-insensitive and every given field must match;
non-breaking and narrow spaces (as in iOS's "7:20 AM") match plain ones. A
match inside another match (a row's label inside the row) counts once. When
several separate elements match, glovebox refuses rather than guess, and lists
them numbered; `index` picks one, with the numbers `find_elements` gives.
`describe_ui` lists what is on screen, one line per element, up to 400 by
default (`max_elements`, at most 2000), marking those scrolled out of view
`off-screen`:

```
Button "About" id=com.apple.settings.general.about frame=(20,338.7,362,52)
CheckBox "Bold Text" value="0" id=ENHANCE_TEXT_LEGIBILITY frame=(40,112.3,322,28)
```

Roles are what the accessibility tree reports, which is not always the UIKit
class: list rows are usually `Button`, and switches are `CheckBox` with value
`0` or `1` (`role: "Switch"` also finds them).

The server sends these conventions to the agent as MCP server instructions
(`Sources/GloveboxServer/Instructions.swift`). Every tool that takes or returns
coordinates also carries one sentence saying they are points, and every tool
that changes the screen says not to sleep or poll after it.

### Web pages, sheets and alerts

The accessibility tree walk sees only the frontmost app's own views. A web
page, Safari's sheets, system alerts and the status bar are drawn by other
processes, so `describe_ui` also hit-tests a 50-point grid over the parts of
the screen the walk left uncovered (`include_web: false` skips it). A point
inside an element an earlier point found is not asked again, and a container
a point lands on (a web page) is read as a subtree, so a web page costs about
0.5 s on the iPhone Duo's inner panel. What the grid finds is reused while the
screen shows exactly the same pixels, so `describe_ui` and then a tap pay for
one grid. Element queries hit-test only when the walk finds no match, or, for
taps and other actions, matches only text: `tap {"label": "General"}` on the
Duo's Settings then lists the sidebar's General button beside the heading
instead of tapping the heading.

On a rotated panel (the open iPhone Duo's inner one) some processes report
frames in the framebuffer's orientation: SpringBoard does. glovebox checks each
process once, by hit-testing one of its elements both ways, and converts its
frames to interface points. Content in another process that reports frames in
its own space (a home screen widget) is listed with `at=(x,y)`, the point it
was found at, instead of a frame.

When a permission alert stays in front of a launched app, `launch_app`
returns at once, naming the alert and its buttons, instead of waiting for an
app that cannot come to the front.

### Waiting without sleeps

Interactions return only after their effect has finished drawing. glovebox
watches the display's frames: it waits up to `settle_response_ms` (default
1000) for the first visible change, then until the screen has been still for
`settle_quiet_ms` (default 250). A screen with nothing animating can deliver
no frames at all (the Duo's home screen); then a hash of its pixels from
before and after the input tells whether it changed. Changes the size of a text cursor are ignored,
so a blinking caret (or a small spinner) does not keep a screen busy. If only
such small changes were drawn, glovebox watches those cells for up to 1.1 s: a
caret blinks back to how it looked before the input, while a counter that went
from 1 to 2 stays changed and counts. The result says how long it
took, whether anything changed ("No visible change" usually means a tap missed),
and `settled: false` if the screen was still animating at `settle_timeout_ms`
(default 10000).

A busy app can take longer than the response window to handle input, and its
screen goes still while its main thread works, which looks settled. So after
the screen settles, glovebox makes a small accessibility read, which the app
answers on its main thread once it has caught up (an idle app answers in tens
of milliseconds). If nothing had changed, the screen gets another 300 ms to
start changing, so a late transition is reported as a change instead of a
miss, which keeps the agent from tapping again. If the screen had changed and
the read took over 150 ms, the app blocked after drawing (a button's highlight,
then its action), so glovebox waits for what it draws once it is free.

Loading spinners count as a still screen, so a tap that starts loading returns
once the rest of the screen settles; use `wait_for` for the loaded content.

- `settle: "ui"` also waits for two identical accessibility snapshots.
- `settle: "none"` returns as soon as the input is sent.
- `launch_app` waits until the app is frontmost and showing UI, not just its
  launch screen, and then for 3.5 s of stillness: cold launches pause for over
  2 s mid-transition (Photos on iOS 26.5, see `docs/probes/`). An app still on
  its launch screen gets "NOT READY" from accessibility reads, retried for up
  to 6 s.
- `wait_for` waits for an element to appear (or disappear with `gone: true`), re-checking when the screen changes.

Each interaction attaches a screenshot of the settled screen (`screenshot:
false` to skip it, `screenshot_scale` to shrink it). One byte for byte the
same as the last image sent is not sent again; the result says so. If taking
it fails, the result says the input still happened, so the agent does not
send it again.

`screenshot_scale` and the three `settle_*_ms` options are accepted by every
interaction, and by the command line, but are not listed in tools/list:
listing them on every tool cost about 1,200 tokens, and agents use `wait_for`
instead.

Interactions on one simulator run one at a time. When an agent sends several
in parallel, each waits for the previous one to finish, so their touches and
keys never interleave. A `batch` holds the simulator for all of its steps.

### Batching

`batch` runs steps in one round trip. Each step is `{"<tool>": {<arguments>}}`
and behaves exactly like the standalone tool, including settling:

```json
{"steps": [
  {"launch_app": {"bundle_id": "com.example.app"}},
  {"tap": {"label": "Email"}},
  {"type_text": {"text": "me@example.com"}},
  {"tap": {"identifier": "loginButton"}},
  {"wait_for": {"label": "Welcome"}},
  {"screenshot": {"scale": 0.5}}
]}
```

It stops at the first failure unless `stop_on_error` is false, and the result
ends with a screenshot of the final screen. Because nothing looks at the
screen between steps:

- each element is looked up right before its step and must hold still across
  two reads before it is tapped;
- an x/y `tap` or `long_press` is allowed only as the first step, where the
  coordinates are fresh; the whole batch is checked before any step runs;
- a failure says which steps already ran, so they are not resent.

A batch takes at most 20 steps. `{"capture": {"path": "/tmp/step3.jpg"}}`
saves a screenshot mid-batch (only under `$TMPDIR` or `/tmp`, never over an
existing file, with symlinks resolved first), and `{"sleep": {"ms": N}}`
exists as an escape hatch. `scroll_to` swipes until an element is in view,
clear of the nav and tab bars, turning around once at the end of the list.

### Keyboard

Keys are sent as hardware keyboard events, so they work in any focused field
without the on-screen keyboard. `type_text` types the US layout. A line with
other characters (accents, emoji) is pasted through the simulator pasteboard,
and Return and Tab are always pressed as keys, so `"submit": true` still
submits after pasted text. Key names:
`return`, `escape`, `backspace`, `delete_forward`, `tab`, `space`, arrows,
`home`, `end`, `page_up`, `page_down`, `f1`–`f12`, single characters, or a hex
HID usage such as `0x2a`. Modifiers: `cmd`, `shift`, `option`, `ctrl`.
Repeated arrow keys go 100 ms apart and other keys 10 ms apart; closer
arrow presses were dropped.

### Debugging

The `debug_*` tools drive lldb through Xcode's `lldb-dap`, so an agent can
stop the app it is driving and look inside. lldb can run shell commands on
the Mac, so these tools are off unless the server runs with
`GLOVEBOX_ENABLE_DEBUG=1` (see [Security](#security)):

```sh
GLOVEBOX_ENABLE_DEBUG=1 scripts/install-local.sh --register
# or
claude mcp add -e GLOVEBOX_ENABLE_DEBUG=1 glovebox -- ~/.local/bin/glovebox-mcp
```

Then:

```json
{"debug_attach": {"bundle_id": "dev.glovebox.TestApp", "breakpoints": ["TestApp.swift:35"]}}
{"tap": {"label": "Submit"}}
{"debug_wait": {}}
{"debug_evaluate": {"expression": "name"}}
{"debug_continue": {}}
```

`debug_attach` relaunches the app waiting for the debugger by default, so
breakpoints catch its first screen (`relaunch: false` attaches as it runs).
While the app is paused its screen is frozen: input tools and `describe_ui`
are refused, and screenshots say so. glovebox refuses system apps and apps
already under Xcode's debugger, and detaches after 10 minutes without a debug
call or when its client disconnects.

### Logs

`get_logs {"bundle_id": "com.example.app"}` matches the app's binary, its
subsystem, and messages naming it, so an app's crash (logged by other
processes) shows up too. The window defaults to 30 s (`since`, at most 10
minutes; an idle simulator logs about 500 KB a second) and the output to the
newest 40 KB (`max_bytes`, at most 200 KB).

### Several agents on one simulator

There is no lock between processes. When another glovebox process drove the
same simulator in the last two minutes, results say so, so an agent knows the
screen may have changed under it.

## Command line

The binary is also a command-line tool; with no arguments (or `serve`) it
serves MCP.

```sh
glovebox-mcp list                                   # the tools
glovebox-mcp tap --label General                    # any tool, flags typed by its schema
glovebox-mcp launch_app com.apple.Preferences       # a bare value fills the main argument
glovebox-mcp describe_ui --json                     # the raw MCP result
glovebox-mcp report                                 # versions and environment for a bug report
glovebox-mcp selftest --udid <udid>                 # end-to-end check in Safari
```

Images are saved to temporary files and their paths printed. Exit codes: 0
success, 1 the tool failed, 2 a bad command line. `scripts/install-local.sh`
also installs a `glovebox` link.

## Testing

- `scripts/gate.sh`: release build without warnings, unit tests, and a check
  that the binary links only system libraries.
- `Tests/GloveboxServerTests/Golden/tools-list.json` is the recorded tools/list;
  a test fails when it changes. Re-record with
  `GLOVEBOX_RECORD_GOLDEN=1 swift test --filter GoldenTests`.
- `GLOVEBOX_LIVE_UDID=<udid> swift test --filter LiveTests` drives Settings on
  that simulator through the tool layer.
- `glovebox-mcp selftest` serves a page with one full-screen blue button, opens
  it in Safari and taps it through a child `glovebox-mcp serve` over JSON-RPC; it
  passes only if the page saw the tap and turned yellow. Its `selftest.json`
  has no times or counts, so passing runs write identical bytes.
- `scripts/run-scenario.sh scenarios/testapp-form.json <udid>` runs a
  scenario (batch steps in a JSON file).
- `docs/probes/` records the measurements glovebox's constants rest on.

## With the Xcode MCP

1. Build the app with the Xcode MCP and note the built `.app` path.
2. `install_app` with that path, then `launch_app` with the bundle ID.
3. Drive it with `describe_ui`, `tap`, `type_text` and `batch`, checking with `screenshot`.

## Troubleshooting

- Set `GLOVEBOX_DEBUG=1` in the server's environment to log frame and settle decisions to stderr.
- `glovebox-mcp report` prints glovebox's, macOS's, Xcode's and CoreSimulator's
  versions, and how input reaches each booted simulator.
- If reading the framebuffer fails, screenshots fall back to `simctl io
  screenshot` (about 0.5 s a capture instead of tens of milliseconds). glovebox
  logs each distinct reason once to stderr. `GLOVEBOX_CAPTURE=simctl` forces the fallback, to test
  it.
- The first accessibility read in a freshly launched app can take a couple of
  seconds while the app loads its accessibility support. Later reads take tens
  of milliseconds.
- If pasting (non-US text in `type_text`) fails with an error, something
  replaced the text on the simulator's pasteboard, most likely Device Hub's
  Use Shared Clipboard, which keeps it in sync with the Mac's clipboard. glovebox
  reads the pasteboard back before pressing Cmd-V, so it never pastes your
  own clipboard into the app.
- If an app is hung, accessibility reads fail with "The app did not answer
  accessibility requests" after a few seconds instead of returning nothing.
- Foldable devices expose several panels; glovebox reads and touches the one
  showing content, and `fold` sweeps the hinge to an angle. Touches go
  through `dtuhidd` wherever it runs; SimulatorKit's touches crash the
  simulator's input system (backboardd) on a device with two built-in panels.
- A panel can draw its interface rotated in its framebuffer, like the open
  iPhone Duo's inner panel (a portrait framebuffer with a landscape
  interface). glovebox reads the rotation from the simulator, so coordinates,
  screenshots and accessibility frames all match the interface as the user
  sees it. Only that panel's rotation (`rot90`) has been checked; other
  rotations, such as a rotated single-panel iPhone, are untested.

## How it works

| Piece | Private API |
|---|---|
| Devices, accessibility requests | CoreSimulator `SimServiceContext`, `SimDevice` |
| Touches, keys, buttons, hinge | XPC to `dtuhidd`, the HID daemon Xcode 27's CoreDevice runs in the simulator (as Device Hub does); see `docs/simulator-input.md` |
| Fallback input without `dtuhidd` | SimulatorKit `SimDeviceLegacyHIDClient` and the `IndigoHIDMessageFor*` builders |
| Debugging | Xcode's `lldb-dap`, a documented Debug Adapter Protocol front end to lldb |
| Interface rotation | The `displayinfo` action of `dtdeviceinfod`, CoreDevice's device-info daemon in the simulator |
| Screenshots, settle detection | The `SimScreen` port's framebuffer IOSurface and per-frame callback |
| UI hierarchy | AccessibilityPlatformTranslation `AXPTranslator` |

Slow or rarely used operations (boot, install, launch, erase, pasteboard,
logs, shake) go through `xcrun simctl`. The private frameworks are loaded with
`dlopen` and never linked, which `scripts/gate.sh` checks.

- [`docs/simulator-input.md`](docs/simulator-input.md): which input path each
  event takes, and the pacing behind it.
- [`docs/simulator-protocols.md`](docs/simulator-protocols.md): the wire
  formats of `dtuhidd` and `dtdeviceinfod`.
- [`docs/probes/`](docs/probes/): the measurements glovebox's constants rest on.

## Known limitations

- Simulators only, no physical devices. Apple silicon, macOS 14 or later and
  Xcode 27, watched through Device Hub; Simulator.app is not supported.
- glovebox uses private Apple frameworks, so a new Xcode can break it. Calls
  into them are guarded, so a missing or changed API fails that call with an
  error instead of crashing the server.
- A simulator rebooted outside glovebox (Xcode, `simctl`) is detected and
  glovebox reconnects. The input clients of earlier boots are kept, not
  released: releasing one after a reboot crashed the simulator's input system.
- A busy app can take longer than the 1 s response window, so a tap may
  return before its effect; raise `settle_response_ms`, or use `wait_for`.
- Rarely, a simulator that has been booted for a long time drops every touch
  while screenshots and `describe_ui` still work. `shutdown`, then `boot`,
  fixes it.
- `debug_attach` (opt-in) debugs only apps you installed, not system apps. Breakpoints
  at `File.swift:line` work; breakpoints on Swift function names are
  unverified.
- Interface rotation has been checked only on the open iPhone Duo's inner
  panel; a rotated single-panel iPhone is untested.

## Security

glovebox is a local stdio server with no network listener (`selftest` serves
its test page on 127.0.0.1 only while it runs). What it can do is what you
allow the agent to call:

- **The device tools act on any simulator** on the Mac: install and launch
  apps, open URLs, erase devices, and read whatever is on screen.
  `launch_app` refuses `DYLD_` environment variables, which would load code
  from the Mac into the app.
- **The `debug_*` tools run code as you,** so they are off by default.
  `debug_evaluate` takes lldb commands as well as expressions, and lldb can
  run shell commands on the Mac. Turn them on with `GLOVEBOX_ENABLE_DEBUG=1`
  only for an agent you trust, approve those calls one at a time, and never
  auto-approve them for an agent that reads untrusted content, such as web
  pages it opens in the simulator.
- **Files:** glovebox writes only new files under `$TMPDIR` or `/tmp`
  (screenshots an agent asks to save, `batch` captures), never over an
  existing file and never through a symlink.
- **Other clients' names:** when another process drove the same simulator,
  its self-chosen name is shown to the agent cut to 60 plain characters.

Report a security problem privately through GitHub's
[security advisories](https://github.com/andrewbecker/glovebox/security/advisories/new)
rather than in an issue.

## Credits

The approach, and parts of the HID, keyboard and accessibility code, are ported
from [facebook/idb](https://github.com/facebook/idb) under the MIT License. See
[NOTICE](NOTICE).

## License

MIT. See [LICENSE](LICENSE).
