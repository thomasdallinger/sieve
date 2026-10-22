#!/usr/bin/env bash
# Builds the app, installs it to /Applications and launches it.
# Extra arguments are passed to the app, e.g. ./scripts/install.sh ~/Downloads
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/app.env
./scripts/build-app.sh
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 0.5
rm -rf "/Applications/$APP_NAME.app"
cp -R "dist/$APP_NAME.app" "/Applications/$APP_NAME.app"
if [[ $# -gt 0 ]]; then open "/Applications/$APP_NAME.app" --args "$@"; else open "/Applications/$APP_NAME.app"; fi
echo "Installed /Applications/$APP_NAME.app"
