#!/usr/bin/env bash
# Builds build/GTasks.app. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

SECRET=Resources/client_secret.json
if [[ ! -f "$SECRET" ]]; then
  echo "Missing $SECRET: download the Desktop-app OAuth client JSON from Google Cloud Console and save it there (see README)." >&2
  exit 1
fi

swift build -c release
APP=build/GTasks.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/GTasks" "$APP/Contents/MacOS/GTasks"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$SECRET" "$APP/Contents/Resources/client_secret.json"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x GTasks 2>/dev/null || true
  rm -rf /Applications/GTasks.app
  cp -R "$APP" /Applications/
  open /Applications/GTasks.app
  echo "Installed to /Applications/GTasks.app"
fi
