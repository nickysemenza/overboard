#!/bin/bash
# Builds the `overboard` CLI in release and symlinks it onto your PATH.
#
# The CLI reads the app's SQLite database read-only and writes copies straight
# to NSPasteboard — the running app captures them into history. It never
# migrates the schema, so keep the app up to date alongside it.
#
# Usage: scripts/install-cli.sh [install-dir]   (default: ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

DEST_DIR="${1:-$HOME/.local/bin}"

echo "Building overboard (release)..."
swift build -c release --package-path OverboardKit --product overboard

BINARY="$(swift build -c release --package-path OverboardKit --show-bin-path)/overboard"
if [ ! -x "$BINARY" ]; then
  echo "error: built binary not found at $BINARY" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
ln -sf "$BINARY" "$DEST_DIR/overboard"

echo "Linked $DEST_DIR/overboard -> $BINARY"
echo "Ensure $DEST_DIR is on your PATH, then run: overboard help"
