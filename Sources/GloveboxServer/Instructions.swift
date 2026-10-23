/// Sent to the client at initialization; clients such as Claude Code add it to
/// the agent's system prompt. Covers what spans tools, so each tool's own
/// description can stay short. The debug line is there only when the debug
/// tools are.
func serverInstructions(debug: Bool) -> String {
    debug ? baseInstructions + "\n" + debugInstructions : baseInstructions
}

private let debugInstructions = """
- To debug the app you are driving: debug_attach (with breakpoints), drive it to the breakpoint, debug_wait, debug_evaluate, debug_continue. While it is paused its screen is frozen and input is refused.
"""

private let baseInstructions = """
glovebox drives iOS Simulators: it reads the screen and the accessibility tree, and sends touches, keys and hardware buttons. It does not build apps; build with Xcode tooling, then use install_app and launch_app.

- Look with describe_ui (text and exact frames, cheaper than an image). It also hit-tests the screen for what the tree walk misses: web pages, Safari sheets, system alerts and the status bar.
- Act on elements by query rather than coordinates, e.g. tap {"label": "General"}. label, identifier and value match exactly; label_contains, value_contains and text_match match substrings. Matching ignores case, and every field given must match. When several separate elements match, glovebox refuses and lists them numbered; pass index to pick one (find_elements gives the same numbers).
- Roles come from the accessibility tree: list rows usually report Button, and switches report CheckBox with value 0 (off) or 1 (on).
- Coordinates are POINTS everywhere: describe_ui frames, x/y arguments, and screenshots at the default scale 1, never device pixels.
- Interactions return only after the screen stops changing, with a screenshot of the result (screenshot: false to skip it; one identical to the last image sent is not resent). Do NOT sleep or poll in your shell between steps. Each result says what was touched and whether the screen changed. "No visible change" means nothing redrew: check the screen before repeating the action, because a repeat acts on whatever is on screen now. If a result says the screenshot failed, the action still happened: do not repeat it.
- Use wait_for for content that loads, and scroll_to to bring an element into view, instead of swiping and looking yourself.
- Use batch to run a known sequence in one call (e.g. fill in and submit a form); it stops at the first failure, and the steps before it are not to be resent.
- If a result notes another client drove the simulator recently, the screen may have changed under you: look before acting.
- udid can be omitted when only one simulator is booted, or once you have used one.
"""
