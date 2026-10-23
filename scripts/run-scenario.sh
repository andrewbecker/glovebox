#!/bin/sh
# Runs a scenario, a JSON array of batch steps, on a simulator:
#   scripts/run-scenario.sh scenarios/settings-general.json [UDID]
# The final screenshot is saved and its path printed.
# Exit code: 0 if every step passed, 1 if one failed, 2 for bad usage.
set -eu
[ $# -ge 1 ] || { echo "usage: $0 scenario.json [udid]" >&2; exit 2; }
[ -f "$1" ] || { echo "no scenario at $1" >&2; exit 2; }
steps=$(cat "$1")
root=$(cd "$(dirname "$0")/.." && pwd)
binary=$root/.build/release/glovebox-mcp
[ -x "$binary" ] || (cd "$root" && swift build -c release 2>&1 | tail -1)
if [ $# -ge 2 ]; then
    exec "$binary" batch --steps "$steps" --udid "$2"
fi
exec "$binary" batch --steps "$steps"
