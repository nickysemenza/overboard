#!/bin/bash
# Cuts a signed, notarized release zip into dist/.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → +).
#   2. An app-specific password for your Apple ID (appleid.apple.com),
#      stored as a notarytool keychain profile:
#        xcrun notarytool store-credentials overboard-notary \
#          --apple-id <your-apple-id> --team-id HDPU3NY6TJ
#
# Usage: scripts/release.sh <version>     e.g. scripts/release.sh 1.0.0
#
# Notes:
# - The hardened runtime is required by notarization; Overboard needs no
#   runtime exception entitlements (Accessibility/CGEvent are TCC-gated,
#   not entitlement-gated).
# - Notarization typically takes a minute or two; --wait blocks until done.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version>}
PROFILE=overboard-notary
DERIVED=build/release
APP="$DERIVED/Build/Products/Release/Overboard.app"
DIST=dist
ZIP="$DIST/Overboard-$VERSION.zip"

mkdir -p "$DIST"

echo "Building Release $VERSION (Developer ID, hardened runtime)…"
xcodebuild -project Overboard.xcodeproj -scheme Overboard \
  -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" \
  build | tail -2

echo "Verifying signature…"
codesign --verify --strict --deep "$APP"

echo "Submitting for notarization…"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling ticket…"
xcrun stapler staple "$APP"

# Re-zip so the published archive contains the stapled app.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Done: $ZIP"
echo "Gatekeeper check:"
spctl --assess --type execute --verbose=2 "$APP"
