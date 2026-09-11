#!/bin/bash
# Notarizes and staples an already Developer-ID-signed Overboard.app, then
# re-zips it for distribution. This script does NOT sign — xcodebuild is
# expected to have already produced a Developer ID Application signature
# (see .github/workflows/release.yml and scripts/release.sh); this script
# only verifies that signature, submits to Apple's notary service, staples
# the resulting ticket, and re-zips.
#
# Usage: scripts/sign-and-notarize.sh <path/to/Overboard.app> <out.zip>
# Env:   NOTARY_KEY_PATH   path to an App Store Connect API key (.p8)
#        NOTARY_KEY_ID     that key's ID
#        NOTARY_ISSUER_ID  the API key's issuer ID
set -euo pipefail

APP=${1:?usage: scripts/sign-and-notarize.sh <path/to/Overboard.app> <out.zip>}
OUT_ZIP=${2:?usage: scripts/sign-and-notarize.sh <path/to/Overboard.app> <out.zip>}

: "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH is required (path to App Store Connect API .p8)}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"

if [ ! -d "$APP" ]; then
    echo "error: app bundle not found at $APP" >&2
    exit 1
fi

echo "Verifying code signature on $APP..."
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Confirming the app is signed with a Developer ID Application identity..."
# Captured first: under pipefail, `grep -q` closing the pipe early makes
# codesign exit on SIGPIPE and the whole pipeline read as a failure.
SIGNATURE_INFO=$(codesign -dvv "$APP" 2>&1)
if ! grep -q "Developer ID Application" <<< "$SIGNATURE_INFO"; then
    echo "error: $APP is not signed with a Developer ID Application identity." >&2
    echo "This script only notarizes an already-signed app — xcodebuild is expected" >&2
    echo "to have signed it (CODE_SIGN_IDENTITY=\"Developer ID Application\")." >&2
    exit 1
fi

TMPDIR_NOTARIZE=$(mktemp -d -t overboard-notarize)
TMPZIP="$TMPDIR_NOTARIZE/Overboard.zip"
cleanup() { rm -rf "$TMPDIR_NOTARIZE"; }
trap cleanup EXIT

echo "Zipping $APP for notarization submission..."
ditto -c -k --keepParent "$APP" "$TMPZIP"

echo "Submitting to Apple notary service (this can take a few minutes)..."
# notarytool exits non-zero on a rejected submission; don't let set -e bail
# here or the log fetch below never runs and the rejection reason is lost.
SUBMIT_JSON=$(xcrun notarytool submit "$TMPZIP" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 20m --output-format json) || true

echo "$SUBMIT_JSON"

SUBMISSION_ID=$(echo "$SUBMIT_JSON" | jq -r '.id // empty')
STATUS=$(echo "$SUBMIT_JSON" | jq -r '.status // empty')

if [ -z "$SUBMISSION_ID" ] || [ -z "$STATUS" ]; then
    echo "error: could not parse submission id/status from notarytool output" >&2
    exit 1
fi

echo "Submission $SUBMISSION_ID finished with status: $STATUS"

if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization was not accepted — fetching the notary log for details..."
    xcrun notarytool log "$SUBMISSION_ID" \
        --key "$NOTARY_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID"
    echo "error: notarization failed with status $STATUS" >&2
    exit 1
fi

echo "Stapling the notarization ticket to $APP..."
xcrun stapler staple "$APP"

echo "Re-zipping the stapled app to $OUT_ZIP..."
rm -f "$OUT_ZIP"
ditto -c -k --keepParent "$APP" "$OUT_ZIP"

echo "Verifying Gatekeeper acceptance..."
SPCTL_OUT=$(spctl -a -vv -t exec "$APP" 2>&1) || {
    echo "$SPCTL_OUT" >&2
    echo "error: spctl assessment failed" >&2
    exit 1
}
echo "$SPCTL_OUT"

if ! echo "$SPCTL_OUT" | grep -q "source=Notarized Developer ID"; then
    echo "error: spctl output does not show source=Notarized Developer ID" >&2
    exit 1
fi

echo "Notarized and stapled: $OUT_ZIP"
