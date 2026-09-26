#!/bin/bash
# Runs the E2E scenarios against a proxy started with up.sh. See README.md for the list.
# Usage: scenarios.sh [--only name1,name2] [--websearch] [--list]
set -euo pipefail
source "$(dirname "$0")/env.sh"
export E2E_DIR E2E_ROOT E2E_PORT E2E_PASSTHROUGH_PORT E2E_APP_SUPPORT
export E2E_LOG_FILE="$(e2e_log_file)"
exec python3 "$E2E_DIR/scenarios.py" "$@"
