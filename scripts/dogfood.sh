#!/bin/bash
# Incremental Debug build for this Mac (from the default DerivedData),
# installed into /Applications and relaunched — the daily-driver loop. Signs with the project's automatic
# Apple Development identity so the Accessibility grant survives the
# rebuild (see README.md § Signing & Accessibility).
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=/Applications/Overboard.app
# Default DerivedData, shared with Xcode and any other xcodebuild — a private
# -derivedDataPath meant every dogfood run was a from-scratch compile of a
# tree Xcode had usually just built. The product path comes from xcodebuild
# itself rather than a hardcoded DerivedData hash.
XCODEBUILD=(xcodebuild -project Overboard.xcodeproj -scheme Overboard -configuration Debug
    -destination "platform=macOS,arch=$(uname -m)" ONLY_ACTIVE_ARCH=YES)
"${XCODEBUILD[@]}" -quiet build
APP="$("${XCODEBUILD[@]}" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR /{print $2}')/Overboard.app"

osascript -e 'tell application "Overboard" to quit' 2>/dev/null || true
pkill -x Overboard 2>/dev/null || true
sleep 1

rm -rf "$DEST"
ditto "$APP" "$DEST"
# Overwriting an installed bundle doesn't make pluginkit rescan its embedded
# Quick Look extension; register the fresh one explicitly.
/usr/bin/pluginkit -a "$DEST/Contents/PlugIns/OverboardQuickLook.appex"
open "$DEST"
