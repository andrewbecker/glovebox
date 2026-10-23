# Settle on cold launches

**Question.** Does glovebox report a launched app "settled" while its first
screen is still in transition? Real launch transitions can pause for over
2 s, longer than the 250 ms quiet window taps use.

**Setup.** Xcode 27.2 (27B48), CoreSimulator 1174.20. An iPhone 17 Pro on
iOS 26.5 (23F77) and an iPhone 18 Pro on iOS 27.2, both freshly created.

**Run 1: compare the settled screen with one 4 s later.** For Photos,
Settings, Calendar, Contacts and Maps: `terminate_app`, home, `launch_app`
(quiet window 250 ms), sleep 4 s, `screenshot`; then count pixels differing by
over 32 in any channel at 100 px wide.

| App | iOS 26.5 | iOS 27.2 |
|---|---|---|
| Photos | 44% differ (settled at 2.5 s, then "What's New" slid in) | 0% |
| Settings | 0% | 0% |
| Calendar | 0% | 0% |
| Contacts | launch failed (see [alert probe](2026-10-23-launch-under-alert.md)) | 3% |
| Maps | launch failed (same) | 0% |

**Run 2: measure the pause.** Photos on iOS 26.5, `GLOVEBOX_DEBUG=1`,
`launch_app` then `wait_for {"label": "Continue"}`; the longest gap between
significant frames was 2159 ms and 2324 ms in two runs.

**Decision.** `launch_app` waits for 3.5 s of stillness, which leaves margin
over the 2.3 s pauses measured here. Taps keep 250 ms: such pauses were not
seen after taps, and 3.5 s would add over 3 s to every input. Both are
adjustable with `settle_quiet_ms`. After the change, run 2's launch returned
with the sheet on screen (7.8 s).
