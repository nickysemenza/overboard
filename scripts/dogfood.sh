#!/bin/bash
# Builds the version you actually use and swaps it into /Applications.
#
# Unlike release.sh (unsigned zip for distribution), this signs with your
# Apple Development identity (team HDPU3NY6TJ, automatic signing) so the
# Accessibility TCC grant survives the rebuild — paste-back stays working
# instead of looking "flaky" after every install. See the signing note in
# README.md for why the stable signature matters.
#
# Usage: scripts/dogfood.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/dogfood
APP="$DERIVED/Build/Products/Release/Overboard.app"
DEST=/Applications/Overboard.app

echo "Building Release..."
xcodebuild -project Overboard.xcodeproj -scheme Overboard \
  -configuration Release -derivedDataPath "$DERIVED" \
  build | tail -2

echo "Quitting running Overboard..."
osascript -e 'tell application "Overboard" to quit' 2>/dev/null || true
# Belt and suspenders: osascript can't reach a menu-bar-only app reliably.
pkill -x Overboard 2>/dev/null || true
sleep 1

echo "Installing to $DEST..."
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Launching..."
open "$DEST"

echo "Done: now running $(/usr/bin/defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
