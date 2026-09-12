#!/bin/bash
# Builds a Debug app for this Mac and swaps it into /Applications.
#
# Like a normal Xcode run, this signs with your
# Apple Development identity (team Y9A97FXT63, automatic signing) so the
# Accessibility TCC grant survives the rebuild — paste-back stays working
# instead of looking "flaky" after every install. See the signing note in
# README.md for why the stable signature matters.
#
# Usage: scripts/dogfood.sh [--release] [--no-build]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION=Debug
SHOULD_BUILD=true
for arg in "$@"; do
    case "$arg" in
        --release) CONFIGURATION=Release ;;
        --no-build) SHOULD_BUILD=false ;;
        -h|--help)
            echo "Usage: $0 [--release] [--no-build]"
            echo "  Default: incremental Debug build for this Mac, install, and launch."
            echo "  --release   Use an optimized build for performance checks."
            echo "  --no-build  Install and launch the last build of the selected configuration."
            exit 0
            ;;
        *) echo "Unknown option: $arg (use --help)" >&2; exit 2 ;;
    esac
done

DERIVED=build/dogfood
APP="$DERIVED/Build/Products/$CONFIGURATION/Overboard.app"
DEST=/Applications/Overboard.app
LOG="$DERIVED/dogfood-$CONFIGURATION.log"

if $SHOULD_BUILD; then
    mkdir -p "$DERIVED"
    echo "Building $CONFIGURATION for $(uname -m)... (log: $LOG)"
    BUILD_STARTED=$SECONDS
    if ! xcodebuild -project Overboard.xcodeproj -scheme Overboard \
        -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED" \
        -destination "platform=macOS,arch=$(uname -m)" ONLY_ACTIVE_ARCH=YES \
        -showBuildTimingSummary build > "$LOG" 2>&1; then
        tail -80 "$LOG" >&2
        exit 1
    fi
    echo "Built in $((SECONDS - BUILD_STARTED))s."
else
    echo "Using the last $CONFIGURATION build (source changes are not rebuilt)."
fi

if [[ ! -x "$APP/Contents/MacOS/Overboard" ]]; then
    echo "No $CONFIGURATION app at $APP. Run without --no-build first." >&2
    exit 1
fi

echo "Quitting running Overboard..."
osascript -e 'tell application "Overboard" to quit' 2>/dev/null || true
# Belt and suspenders: osascript can't reach a menu-bar-only app reliably.
pkill -x Overboard 2>/dev/null || true
sleep 1

echo "Installing to $DEST..."
rm -rf "$DEST"
ditto "$APP" "$DEST"

EXTENSION="$DEST/Contents/PlugIns/OverboardQuickLook.appex"
if [[ -d "$EXTENSION" ]]; then
    # Replacing an already-installed bundle does not reliably cause pluginkit
    # to rescan embedded Quick Look extensions. Register it explicitly so the
    # next Finder Quick Look request sees the just-built provider.
    /usr/bin/pluginkit -a "$EXTENSION"
fi

echo "Launching..."
open "$DEST"

echo "Done: now running $(/usr/bin/defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
