#!/bin/sh
# Builds glovebox and installs it where Claude Code (or any MCP client) can find it:
#   scripts/install-local.sh            # to ~/.local/bin
#   PREFIX=/usr/local/bin scripts/install-local.sh
# Installs glovebox-mcp and a `glovebox` link to it, so `glovebox tap --label OK`
# works from a shell. Prints the command that registers the server; pass
# --register to run it.
set -eu
cd "$(dirname "$0")/.."
prefix=${PREFIX:-$HOME/.local/bin}

swift build -c release 2>&1 | tail -1
mkdir -p "$prefix"
# Copy to a temporary name, then rename, so a running server keeps its binary.
cp .build/release/glovebox-mcp "$prefix/.glovebox-mcp.new"
mv -f "$prefix/.glovebox-mcp.new" "$prefix/glovebox-mcp"
ln -sf glovebox-mcp "$prefix/glovebox"
echo "Installed $prefix/glovebox-mcp ($("$prefix/glovebox-mcp" --version)) and $prefix/glovebox"

# GLOVEBOX_ENABLE_DEBUG=1 registers the server with the debug tools on.
debug=
[ "${GLOVEBOX_ENABLE_DEBUG:-}" = 1 ] && debug="-e GLOVEBOX_ENABLE_DEBUG=1"
register="claude mcp add --scope user $debug glovebox -- $prefix/glovebox-mcp"
if [ "${1:-}" = "--register" ]; then
    $register
else
    echo "To register it with Claude Code: $register"
fi
case ":$PATH:" in
    *":$prefix:"*) ;;
    *) echo "Note: $prefix is not on PATH; add it to use the glovebox command." ;;
esac
