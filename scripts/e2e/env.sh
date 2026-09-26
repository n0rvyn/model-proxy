# Shared settings for the ModelProxy E2E harness. Sourced by the other scripts; see README.md.

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$E2E_DIR" rev-parse --show-toplevel)"

# Everything the harness creates lives here (builds, Claude Code home, workspace, logs of runs).
E2E_ROOT="${MP_E2E_ROOT:-${TMPDIR%/}/modelproxy-e2e}"
# Mapped client port and a second client whose unmapped models pass through to Anthropic.
E2E_PORT="${MP_E2E_PORT:-19090}"
E2E_PASSTHROUGH_PORT="${MP_E2E_PASSTHROUGH_PORT:-19092}"
E2E_BUNDLE_ID="com.90percent.ModelProxy.e2e"
# The E2E build is not sandboxed, so AppPaths.appSupport resolves here (the App Store app uses its container).
E2E_APP_SUPPORT="$HOME/Library/Application Support/ModelProxy"
E2E_MARKER="$E2E_APP_SUPPORT/.modelproxy-e2e"
E2E_PID_FILE="$E2E_ROOT/app.pid"
E2E_MODEL="${MP_E2E_MODEL:-deepseek-flash}"

e2e_log_file() {
    echo "$E2E_APP_SUPPORT/logs/modelproxy-$(date +%F).log"
}

# Reads a value from the environment first, then from $REPO_ROOT/.env (NAME=value lines).
e2e_secret() {
    local name="$1" value="${!1:-}"
    if [ -z "$value" ] && [ -f "$REPO_ROOT/.env" ]; then
        value="$(grep -E "^${name}=" "$REPO_ROOT/.env" | tail -1 | cut -d= -f2-)"
    fi
    # Legacy .env layout ("KEY：…" / "Engine ID：…", full-width colons) holds the Google credentials.
    if [ -z "$value" ] && [ -f "$REPO_ROOT/.env" ]; then
        case "$name" in
            GOOGLE_SEARCH_API_KEY) value="$(grep -E "^KEY[：:]" "$REPO_ROOT/.env" | sed -E 's/^KEY[：:] *//')" ;;
            GOOGLE_SEARCH_ENGINE_ID) value="$(grep -E "^Engine ID[：:]" "$REPO_ROOT/.env" | sed -E 's/^Engine ID[：:] *//')" ;;
        esac
    fi
    printf '%s' "$value" | tr -d '\r'
}

e2e_die() {
    echo "e2e: $*" >&2
    exit 1
}
