#!/usr/bin/env bash
# Pinned developer tools, shared by CI and local dev so lint/format results
# never drift between the two. Downloads the exact GitHub release
# binaries into .tools/ (gitignored) and exposes them via .tools/bin.
#
#   scripts/tools.sh install     # fetch anything missing
#   scripts/tools.sh lint        # swiftformat --lint + swiftlint --strict
#   scripts/tools.sh format      # rewrite sources with swiftformat
#
# Bump versions here and nowhere else.
set -euo pipefail

SWIFTLINT_VERSION=0.65.0
SWIFTFORMAT_VERSION=0.61.1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
BIN="$TOOLS/bin"

# fetch <name> <version> <url> — downloads and unzips into a versioned dir,
# then links the binary into .tools/bin. No-op when already present.
fetch() {
    local name=$1 version=$2 url=$3
    local dir="$TOOLS/$name-$version"
    if [[ ! -x "$dir/$name" ]]; then
        echo "→ $name $version"
        rm -rf "$dir" && mkdir -p "$dir"
        curl -fsSL -o "$dir/archive.zip" "$url"
        unzip -q -o "$dir/archive.zip" -d "$dir"
        rm "$dir/archive.zip"
        # Some archives nest the binary one level down.
        if [[ ! -x "$dir/$name" ]]; then
            found=$(find "$dir" -type f -name "$name" -perm -u+x | head -n 1)
            [[ -n "$found" ]] && ln -sf "$found" "$dir/$name"
        fi
        chmod +x "$dir/$name"
    fi
    mkdir -p "$BIN"
    ln -sf "$dir/$name" "$BIN/$name"
}

install() {
    fetch swiftformat "$SWIFTFORMAT_VERSION" \
        "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip"
    fetch swiftlint "$SWIFTLINT_VERSION" \
        "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
    echo "tools ready in $BIN"
}

case "${1:-install}" in
    install) install ;;
    lint)
        install >/dev/null
        cd "$ROOT"
        "$BIN/swiftformat" --lint .
        "$BIN/swiftlint" --strict
        ;;
    format)
        install >/dev/null
        cd "$ROOT" && "$BIN/swiftformat" .
        ;;
    *)
        echo "usage: $0 {install|lint|format}" >&2
        exit 2
        ;;
esac
