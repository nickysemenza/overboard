#!/bin/bash
# Incremental Debug build for this Mac, installed into /Applications and
# relaunched — the daily-driver loop. Signs with the project's automatic
# Apple Development identity so the Accessibility grant survives the
# rebuild (see README.md § Signing & Accessibility).
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/dogfood
APP="$DERIVED/Build/Products/Debug/Overboard.app"
DEST=/Applications/Overboard.app

xcodebuild -project Overboard.xcodeproj -scheme Overboard -configuration Debug \
    -derivedDataPath "$DERIVED" -destination "platform=macOS,arch=$(uname -m)" \
    ONLY_ACTIVE_ARCH=YES -quiet build

osascript -e 'tell application "Overboard" to quit' 2>/dev/null || true
pkill -x Overboard 2>/dev/null || true
sleep 1

rm -rf "$DEST"
ditto "$APP" "$DEST"
# Overwriting an installed bundle doesn't make pluginkit rescan its embedded
# Quick Look extension; register the fresh one explicitly.
/usr/bin/pluginkit -a "$DEST/Contents/PlugIns/OverboardQuickLook.appex"
open "$DEST"
