#!/bin/bash
# Stops the E2E app and deletes everything that holds keys or request bodies.
# Usage: down.sh [--all]   (--all also removes builds, the Claude Code home and baseline worktrees)
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [ -f "$E2E_PID_FILE" ]; then
    pid="$(cat "$E2E_PID_FILE")"
    if ps -p "$pid" -o command= 2>/dev/null | grep -q "ModelProxy.app/Contents/MacOS/ModelProxy"; then
        kill "$pid"
    fi
    rm -f "$E2E_PID_FILE"
fi
pkill -f "$E2E_DIR/capture_proxy.py" 2>/dev/null || true

# config.json holds the vendor and search keys in plaintext.
if [ -f "$E2E_MARKER" ]; then
    rm -rf "$E2E_APP_SUPPORT"
fi
rm -rf "$E2E_ROOT/capture"

if [ "${1:-}" = "--all" ]; then
    for src in "$E2E_ROOT"/src-*; do
        [ -d "$src" ] && git -C "$REPO_ROOT" worktree remove --force "$src"
    done
    rm -rf "$E2E_ROOT"
fi
echo "E2E environment cleaned"
