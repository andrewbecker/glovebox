#!/bin/sh
# The check before calling a change done:
#   scripts/gate.sh
# 1. a release build with no warnings in glovebox's own code (an incremental
#    build repeats warnings only for files it recompiles; run
#    `swift package clean` first for a full check),
# 2. the unit tests (and the tools/list golden),
# 3. the release binary links no private framework: glovebox loads those at
#    runtime from the selected Xcode, so a link would pin it to one Xcode.
#    libSystem must show up, so an empty otool output cannot pass.
# Set GLOVEBOX_LIVE_UDID to also run the live suite on that simulator.
set -eu
cd "$(dirname "$0")/.."

echo "== release build"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
swift build -c release 2>&1 | tee "$log" | tail -1
if grep -E "^/.*/(Sources|Tests)/.*warning:" "$log"; then
    echo "FAIL: warnings in glovebox's sources" >&2
    exit 1
fi

echo "== unit tests"
swift test 2>&1 | grep -E "Test run with|error:|recorded an issue" || true
swift test >/dev/null 2>&1 || { echo "FAIL: swift test" >&2; exit 1; }

echo "== linked libraries"
binary=.build/release/glovebox-mcp
libraries=$(otool -L "$binary" | tail -n +2)
echo "$libraries" | grep -q "/usr/lib/libSystem.B.dylib" || { echo "FAIL: otool found no libSystem; is $binary a Mach-O?" >&2; exit 1; }
if echo "$libraries" | grep -E "PrivateFrameworks|CoreSimulator|SimulatorKit|AccessibilityPlatformTranslation|Xcode.app"; then
    echo "FAIL: the binary links a private or Xcode framework" >&2
    exit 1
fi
echo "only system libraries"

if [ -n "${GLOVEBOX_LIVE_UDID:-}" ]; then
    echo "== live suite on $GLOVEBOX_LIVE_UDID"
    swift test --filter LiveTests 2>&1 | grep -E "Test run with|recorded an issue"
fi
echo "gate passed"
