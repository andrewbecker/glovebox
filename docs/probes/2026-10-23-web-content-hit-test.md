# Web content by hit-testing

**Setup.** Safari on an iPhone 18 Pro, iOS 27.2, showing a local page with a
heading, a paragraph, an email field, a button that turns the page yellow, and
a link.

**Run.** `describe_ui` before and after adding the hit-test grid;
`describe_point` at points on the page.

**Result.** The tree walk listed only Safari's toolbar. `describe_point` at
(80,160) and (80,260) found "Some paragraph text." and "Go Button". With the
grid (50-point spacing over uncovered areas, plus a row every 25 points along
empty bars), 131 points took about 400 ms and found 11 elements: the
heading, paragraph, field, button, link, and the status bar's time, signal,
Wi-Fi and battery. `tap {"label": "Go Button"}` turned the page yellow, and
`type_text {"text_match": "you@", ...}` typed into the field.

**Decision.** `describe_ui` hit-tests by default (`include_web: false` skips
it); element queries hit-test only when the walk finds no match, so ordinary
queries cost one walk. The grid stops after 2 s.
