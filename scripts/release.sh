#!/bin/bash
# Cuts a release zip into dist/ — unsigned, since there's no paid Apple
# Developer Program membership (no Developer ID cert, no notarization).
# The linker ad-hoc signs arm64 binaries automatically; downloaders clear
# Gatekeeper with right-click → Open the first time.
#
# Tag pushes (v*) cut the same zip on CI and attach it to a GitHub Release
# (.github/workflows/release.yml), so this script is just the local variant.
#
# Usage: scripts/release.sh <version>     e.g. scripts/release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version>}
DERIVED=build/release
APP="$DERIVED/Build/Products/Release/Overboard.app"
DIST=dist
ZIP="$DIST/Overboard-$VERSION.zip"

mkdir -p "$DIST"

echo "Building Release $VERSION (unsigned)…"
xcodebuild -project Overboard.xcodeproj -scheme Overboard \
  -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" \
  build | tail -2

ditto -c -k --keepParent "$APP" "$ZIP"

echo "Done: $ZIP"
echo "Note: unsigned — first launch needs right-click → Open (Gatekeeper)."
