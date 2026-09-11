#!/bin/bash
# Cuts a release zip into dist/ — the local mirror of
# .github/workflows/release.yml.
#
# If a "Developer ID Application" identity is in your keychain, this builds
# signed exactly like CI does, then notarizes and staples via
# scripts/sign-and-notarize.sh when NOTARY_KEY_PATH/NOTARY_KEY_ID/
# NOTARY_ISSUER_ID are all set (same env vars the workflow passes that
# script). Without those three set, it stops after signing — the zip is
# signed but not notarized, and Gatekeeper will still complain on first
# launch until it's been through notarytool.
#
# Without a Developer ID identity at all, it falls back to the old unsigned
# path: the linker ad-hoc signs arm64 binaries automatically, and downloaders
# clear Gatekeeper with right-click → Open the first time.
#
# Tag pushes (v*) cut the signed+notarized zip on CI and attach it to a
# GitHub Release (.github/workflows/release.yml); this script is the local
# variant of the same pipeline.
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

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "Building Release $VERSION (Developer ID signed)…"
    # DEVELOPMENT_TEAM=Y9A97FXT63: the paid Developer Program team (same as
    # the project file), stated explicitly because the identity lookup is
    # keyed on it — any other team fails with "No 'Developer ID Application'
    # signing certificate matching team ID".
    #
    # CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: `xcodebuild build` (unlike
    # `archive`) injects com.apple.security.get-task-allow into the
    # signature by default, which the notary service rejects outright.
    xcodebuild -project Overboard.xcodeproj -scheme Overboard \
        -configuration Release -derivedDataPath "$DERIVED" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="Developer ID Application" \
        DEVELOPMENT_TEAM=Y9A97FXT63 \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        MARKETING_VERSION="$VERSION" \
        build | tail -2

    if [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
        scripts/sign-and-notarize.sh "$APP" "$ZIP"
    else
        ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Done: $ZIP"
        echo "Note: signed but not notarized — set NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER_ID to notarize."
    fi
else
    echo "No Developer ID Application identity found — building unsigned…"
    xcodebuild -project Overboard.xcodeproj -scheme Overboard \
        -configuration Release -derivedDataPath "$DERIVED" \
        CODE_SIGNING_ALLOWED=NO \
        MARKETING_VERSION="$VERSION" \
        build | tail -2

    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "Done: $ZIP"
    echo "Note: unsigned — first launch needs right-click → Open (Gatekeeper)."
fi
