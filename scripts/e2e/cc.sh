#!/bin/bash
# Runs Claude Code against the E2E proxy with nothing inherited from your own Claude Code setup:
# empty environment, its own CLAUDE_CONFIG_DIR (sessions, settings, credentials) and its own workspace.
# Usage: cc.sh -p "prompt" --model claude-sonnet-5 [claude flags...]
#        MP_E2E_BASE_URL=http://127.0.0.1:19091 cc.sh ...   (e.g. through capture_proxy.py)
set -euo pipefail
source "$(dirname "$0")/env.sh"

mkdir -p "$E2E_ROOT/cc-home" "$E2E_ROOT/cc-tmp" "$E2E_ROOT/work"
cd "$E2E_ROOT/work"
exec env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/usr/sbin:/usr/local/bin:$HOME/.local/bin" \
    TERM=xterm-256color LANG=en_US.UTF-8 TMPDIR="$E2E_ROOT/cc-tmp" \
    CLAUDE_CONFIG_DIR="$E2E_ROOT/cc-home" \
    ANTHROPIC_BASE_URL="${MP_E2E_BASE_URL:-http://127.0.0.1:$E2E_PORT}" \
    ANTHROPIC_API_KEY=sk-ant-e2e-dummy \
    CLAUDE_CODE_GATEWAY_HINT_HEADERS=1 DISABLE_AUTOUPDATER=1 \
    "$(command -v claude || echo "$HOME/.local/bin/claude")" "$@"
