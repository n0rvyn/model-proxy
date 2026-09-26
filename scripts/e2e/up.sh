#!/bin/bash
# Writes the isolated config, launches the E2E build and starts its proxy listeners.
# Usage: up.sh [path/to/ModelProxy.app]   (defaults to the last build.sh output)
set -euo pipefail
source "$(dirname "$0")/env.sh"

app="${1:-$(cat "$E2E_ROOT/last-app-path" 2>/dev/null || true)}"
[ -d "$app" ] || e2e_die "no app; run build.sh first"
[ "$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier)" = "$E2E_BUNDLE_ID" ] \
    || e2e_die "$app is not an E2E build (bundle ID must be $E2E_BUNDLE_ID)"

for p in "$E2E_PORT" "$E2E_PASSTHROUGH_PORT"; do
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
        e2e_die "port $p is already in use; run down.sh or pick MP_E2E_PORT / MP_E2E_PASSTHROUGH_PORT"
    fi
done

# The folder is only created by the harness. Refuse to touch one that some other build left behind.
if [ -d "$E2E_APP_SUPPORT" ] && [ ! -f "$E2E_MARKER" ]; then
    e2e_die "$E2E_APP_SUPPORT exists and was not created by this harness; move it away first"
fi

DEEPSEEK_API_KEY="$(e2e_secret DEEPSEEK_API_KEY)"
[ -n "$DEEPSEEK_API_KEY" ] || e2e_die "DEEPSEEK_API_KEY is not set (environment or .env)"
GOOGLE_SEARCH_API_KEY="$(e2e_secret GOOGLE_SEARCH_API_KEY)"
GOOGLE_SEARCH_ENGINE_ID="$(e2e_secret GOOGLE_SEARCH_ENGINE_ID)"

mkdir -p "$E2E_APP_SUPPORT" "$E2E_ROOT"
touch "$E2E_MARKER"
DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" GOOGLE_SEARCH_API_KEY="$GOOGLE_SEARCH_API_KEY" \
GOOGLE_SEARCH_ENGINE_ID="$GOOGLE_SEARCH_ENGINE_ID" MP_E2E_MODEL="$E2E_MODEL" \
E2E_PORT="$E2E_PORT" E2E_PASSTHROUGH_PORT="$E2E_PASSTHROUGH_PORT" \
    python3 "$E2E_DIR/gen_config.py" "$E2E_APP_SUPPORT/config.json"

open -n "$app"
pid=""
for _ in $(seq 1 20); do
    pid="$(pgrep -f "$app/Contents/MacOS/ModelProxy" | head -1 || true)"
    [ -n "$pid" ] && break
    sleep 0.5
done
[ -n "$pid" ] || e2e_die "app did not start"
echo "$pid" > "$E2E_PID_FILE"

# The proxy starts when the menu bar popover first appears, as it does for a user. Click this
# process's own status item (the installed App Store copy has an identical icon).
sleep 2
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to click menu bar item 1 of menu bar 2" >/dev/null \
    || e2e_die "could not click the menu bar item (grant Accessibility to your terminal)"
for _ in $(seq 1 30); do
    if lsof -nP -iTCP:"$E2E_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
        && lsof -nP -iTCP:"$E2E_PASSTHROUGH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "E2E proxy up: pid $pid, mapped port $E2E_PORT, passthrough port $E2E_PASSTHROUGH_PORT"
        exit 0
    fi
    sleep 0.5
done
e2e_die "proxy did not start listening on $E2E_PORT / $E2E_PASSTHROUGH_PORT"
