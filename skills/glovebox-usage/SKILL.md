---
name: glovebox-usage
description: How to drive an iOS Simulator with glovebox's tools (tap, describe_ui, type_text, scroll_to, wait_for, batch, debug_*). Use when testing or exploring an iOS app on a simulator, reproducing a UI bug, filling in a form in an app, or checking that a change works on screen.
---

# Driving a simulator with glovebox

glovebox does not build apps. Build with Xcode (or `xcodebuild`), then
`install_app` with the `.app` path and `launch_app` with its bundle ID.

## The loop

1. **Look** with `describe_ui`: one line per element with its role, label,
   identifier and frame. It is cheaper than a screenshot and gives exact
   labels. Copy labels from it byte for byte.
2. **Act** by query, not coordinates: `tap {"label": "General"}`,
   `type_text {"identifier": "email", "text": "me@example.com"}`. If several
   elements match, glovebox refuses and lists them numbered; add `role` or
   `identifier`, or pass `index`.
3. **Read the result.** Every input waits for the screen to settle and returns
   a screenshot. Do not sleep or poll between steps. "No visible change" means
   nothing redrew: look before repeating, since a repeat acts on whatever is
   on screen now.

## Habits that save calls

- Rows below the fold: `scroll_to {"label": "Privacy & Security"}`, not
  repeated swipes.
- Content that loads: `wait_for {"label": "Welcome"}` (`gone: true` to wait
  for a spinner to leave).
- A known sequence: `batch` with steps like `{"tap": {"label": "Next"}}`. It
  stops at the first failure; do not resend the steps before it.
- Settings rows often combine label and value: "iOS Version, 27.2". Use
  `label_contains` or the row's `identifier`.
- Switches are `CheckBox` with value 0 or 1; list rows are usually `Button`.
- Web pages, Safari sheets and system alerts are found by hit-testing, so
  `describe_ui` lists them too; tap them by label like anything else.
- A permission alert in front of a launched app is named in `launch_app`'s
  result; tap one of its buttons.
- Coordinates, when needed, are points: read them off `describe_ui` frames or
  a scale-1 screenshot.

## Debugging the app while driving it

The `debug_*` tools exist only when the server runs with
`GLOVEBOX_ENABLE_DEBUG=1`; if they are missing, ask the person to turn them on
rather than working around it.

```
debug_attach {"bundle_id": "com.example.app", "breakpoints": ["CartView.swift:88"]}
tap {"label": "Checkout"}        # the result says the app stopped
debug_wait                       # where: reason and stack
debug_evaluate {"expression": "cart.items.count"}
debug_continue
debug_detach
```

While the app is paused, its screen is frozen, so input and `describe_ui` are
refused until `debug_continue`.

## When something is off

- `get_logs {"bundle_id": "com.example.app", "since": "60s"}` shows the
  app's logs and its crash.
- `glovebox-mcp report` (in a shell) prints the versions that matter for a bug
  report; `glovebox-mcp selftest` checks input end to end in Safari.
