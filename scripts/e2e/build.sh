#!/bin/bash
# Builds an isolated E2E copy of ModelProxy: separate bundle ID, no App Sandbox, ad-hoc signed.
# Usage: build.sh            build the current working tree
#        build.sh <git-ref>  build that ref from a temporary worktree (for baseline comparisons)
# Prints the .app path on the last line.
set -euo pipefail
source "$(dirname "$0")/env.sh"

ref="${1:-}"
mkdir -p "$E2E_ROOT"
if [ -n "$ref" ]; then
    name="ref-$(echo "$ref" | tr -c 'A-Za-z0-9._-' '_')"
    src="$E2E_ROOT/src-$name"
    if [ ! -d "$src" ]; then
        git -C "$REPO_ROOT" worktree add -q --detach "$src" "$ref"
    fi
else
    name="worktree"
    src="$REPO_ROOT"
fi

# Network entitlements only: without the sandbox, config and logs live in ~/Library/Application Support/ModelProxy.
entitlements="$E2E_ROOT/e2e.entitlements"
cat > "$entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.network.server</key><true/>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
EOF

derived="$E2E_ROOT/dd-$name"
log="$E2E_ROOT/build-$name.log"
if ! xcodebuild -project "$src/ModelProxy.xcodeproj" -scheme ModelProxy -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$derived" \
    PRODUCT_BUNDLE_IDENTIFIER="$E2E_BUNDLE_ID" ENABLE_APP_SANDBOX=NO \
    CODE_SIGN_ENTITLEMENTS="$entitlements" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    build > "$log" 2>&1; then
    grep -E "error:" "$log" | head -20 >&2
    e2e_die "build failed, see $log"
fi

app="$derived/Build/Products/Debug/ModelProxy.app"
echo "$app" > "$E2E_ROOT/last-app-path"
echo "$app"
