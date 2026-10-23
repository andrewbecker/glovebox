# Launch under a system alert

**Setup.** iPhone 17 Pro, iOS 26.5. Calendar's first launch asked for
location access, and the alert stayed up.

**Run.** `launch_app` for Contacts, then Maps.

**Result before.** Each failed after 30 s: "Process N did not become the
frontmost app (frontmost pid: 19467)". Pid 19467 was SpringBoard, which hosts
the alert; the tree read showed the alert's text and three buttons.

**Result after.** `launch_app` checks, from 2 s into the wait, whether
SpringBoard is frontmost with an alert-like tree (one to four buttons, some
text, at most 12 elements), and returns in 3.6 s: "Launched ..., but a system
alert is in front of it: "Allow “Calendar” to use your location? ..." with
buttons [Allow Once] [Allow While Using App] [Don’t Allow]".

A first version did not require SpringBoard and took TestApp's form (four
buttons, a text) for an alert when Settings failed to come to the front.
That launch failure was seen once and not reproduced.
