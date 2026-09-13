#!/bin/bash
# Notarizes, staples, and zips an already Developer-ID-signed Overboard.app.
# Signing happened in xcodebuild (see .github/actions/build-signed/action.yml).
#
# Usage: scripts/notarize.sh <path/to/Overboard.app> <out.zip>
# Env:   NOTARY_KEY_PATH  NOTARY_KEY_ID  NOTARY_ISSUER_ID  (App Store Connect API key)
set -euo pipefail

APP=${1:?usage: scripts/notarize.sh <path/to/Overboard.app> <out.zip>}
OUT_ZIP=${2:?usage: scripts/notarize.sh <path/to/Overboard.app> <out.zip>}
: "${NOTARY_KEY_PATH:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"
KEY=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

# Fail here, in seconds, rather than after a notary round trip.
codesign --verify --deep --strict "$APP"

TMP=$(mktemp -d -t overboard-notarize)
trap 'rm -rf "$TMP"' EXIT
ditto -c -k --keepParent "$APP" "$TMP/Overboard.zip"

# notarytool exits non-zero on rejection; keep going so the log can be fetched.
RESULT=$(xcrun notarytool submit "$TMP/Overboard.zip" "${KEY[@]}" --wait --timeout 20m --output-format json) || true
echo "$RESULT"
ID=$(jq -r '.id // empty' <<< "$RESULT")
STATUS=$(jq -r '.status // empty' <<< "$RESULT")
if [ "$STATUS" != "Accepted" ]; then
    [ -n "$ID" ] && xcrun notarytool log "$ID" "${KEY[@]}"
    echo "error: notarization status '${STATUS:-unknown}'" >&2
    exit 1
fi

xcrun stapler staple "$APP"
rm -f "$OUT_ZIP"
ditto -c -k --keepParent "$APP" "$OUT_ZIP"
spctl -a -vv -t exec "$APP"
echo "Notarized and stapled: $OUT_ZIP"
