#!/bin/sh
#
# Bakes git state into the built Info.plist, read back at runtime by
# AppVersion (OverboardCore). Run from the "Embed git version" build phase.
#
# CFBundleShortVersionString comes from the nearest git tag, not from a
# checked-in MARKETING_VERSION. The checked-in value silently went stale
# between v0.1.0 and v0.2.0, and every locally built app then called itself
# 0.1.0 — which UpdateChecker compared against the latest GitHub release and
# reported as a permanent, bogus "update available". Tags are the single
# source of truth now; there is no number left to remember to bump.
#
# The value is raised to the tag, never lowered to it, so an explicit
# MARKETING_VERSION= on the xcodebuild line still wins whenever it is ahead of
# the last tag. That keeps `scripts/release.sh 0.4.0` honest when it builds
# 0.4.0 before v0.4.0 exists.
#
# GitDescribe/GitSHA are the honest counterpart to the tag: a build two commits
# past v0.3.0 still calls itself 0.3.0 (true to the tag) while describing as
# v0.3.0-2-gabc1234 (true to the bits). AppVersion.isDirtyOrAhead keys off it.
#
# Best-effort throughout — never fail a build over version metadata. With no
# git and no tags, whatever the project file set stands.
set -e

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$plist" ]; then
    echo "warning: Embed git version: Info.plist not found at $plist"
    exit 0
fi

cd "${SRCROOT}"

set_key() {
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist"
}

get_key() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true
}

set_key GitDescribe "$(git describe --tags --always --dirty 2>/dev/null || true)"
set_key GitSHA "$(git rev-parse --short HEAD 2>/dev/null || true)"

# Nearest tag, minus the conventional leading "v".
tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
version=${tag#v}

# Only a clean dotted-numeric core is usable. A non-release tag ("nightly") or
# a malformed one must leave the project's value alone rather than write
# something SemanticVersion parses to nil — that would silently disable the
# update check instead of failing loudly.
case "$version" in
    '' | *[!0-9.]* | *..* | .* | *.) exit 0 ;;
    *.*) ;;
    *) exit 0 ;; # bare integer — not a release tag
esac

# Raise to the tag, never lower. sort -V orders 0.10.0 above 0.9.0, matching
# SemanticVersion's per-component numeric comparison.
current=$(get_key CFBundleShortVersionString)
highest=$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n 1)

if [ "$highest" = "$version" ]; then
    set_key CFBundleShortVersionString "$version"
fi
