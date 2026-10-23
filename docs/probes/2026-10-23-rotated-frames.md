# Frames on a rotated panel, and grid cost

**Setup.** iPhone Duo, open, iOS 27.1 runtime, Xcode 27.2. The inner panel's
framebuffer is 669x951 points with the interface rotated 90° into a 951x669
landscape. Also a throwaway iPhone 17 Pro on iOS 27.2 (no rotation).

**Run.** On the Duo's home screen: `describe_ui`, a screenshot, and
`describe_point` at the Settings icon as drawn, (500, 80). In Settings and in
Safari (a local page with a heading, a field, five links, a button and a
paragraph): `describe_ui` with `GLOVEBOX_DEBUG=1`, timing the hit-test grid.

**Result.**

- SpringBoard reported the Settings icon at (52,417.3,86.7,68), its place in
  the framebuffer's orientation; on screen it is at (465.7,52,68,86.7). Its
  root reported 466x678. `describe_point` at (500,80) found the icon with the
  framebuffer frame, and `tap {"label": "Settings"}` was refused as covered.
  Settings and Safari report interface frames (their roots report the
  framebuffer's 669x951). Home screen widget content found by hit-testing
  reports frames in the widget's own space, e.g. (17.3,176.3,19.3,15.7).
- Grid, before and after skipping points inside found elements, the 3-trip
  check of a repeated element, and reading hit containers as subtrees:
  Settings (sidebar, 181 points) 600 → 310 ms with all 12 sidebar elements;
  Safari (247 points) over 2 s, stopped by the time limit before the page's
  button, → 0.5 s with every element; the home screen (167 points) about
  0.5 s. The iPhone 17 Pro's Settings, 37 points, 250 ms.
- Covering a container's whole rect once its subtree was read lost the
  Duo's sidebar rows: the sidebar's subtree gave the Apple Account row only.

**Decision.** Each process is checked once per panel orientation by
hit-testing a small leaf at its center read both ways; framebuffer-oriented
processes have their frames converted. Roots report the interface size.
Hits that contain neither the point nor its framebuffer twin keep `at`.
Subtree leaves cover their own rects; containers cover nothing.
