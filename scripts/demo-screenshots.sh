#!/bin/bash
# Regenerates the README demo screenshots in docs/screenshots/.
#
# Builds a Debug Overboard (debug hooks are #if DEBUG), launches it with
# OVERBOARD_DEMO=1 (in-memory store seeded by DemoSeed.swift — no real
# clipboard data), drives the overlay through distributed-notification
# commands on com.nickysemenza.overboard.demo, and captures the live panel
# with `screencapture -l <windowID>`.
#
# Requirements / notes:
# - Screen Recording permission for the terminal running this script
#   (System Settings → Privacy & Security → Screen Recording). The first
#   run without it produces black/empty PNGs — grant and re-run.
# - Quit the daily-driver Overboard first; the script refuses to run
#   alongside it (two instances would both match the window lookup).
# - The panel is transparent with no window shadow, so captures are
#   transparent-margin PNGs and the glass material renders without the
#   desktop backdrop behind it — clean on both GitHub light and dark.
#   If a real blurred-wallpaper look is ever wanted, capture the panel's
#   screen rect instead: `screencapture -x -R x,y,w,h` over a wallpaper.
# - Captures are 2x on Retina; the README embeds with explicit widths.
# - Run on the built-in display and keep the mouse still between shots
#   (the panel follows the screen with the mouse).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=docs/screenshots
DERIVED=build/demo
APP="$DERIVED/Build/Products/Debug/Overboard.app"
NOTE=com.nickysemenza.overboard.demo
mkdir -p "$OUT"

if pgrep -xq Overboard; then
  echo "error: Overboard is already running — quit it first (menu bar → Quit)." >&2
  exit 1
fi

echo "Building (Debug)…"
xcodebuild -project Overboard.xcodeproj -scheme Overboard \
  -configuration Debug -derivedDataPath "$DERIVED" build | tail -2

OVERBOARD_DEMO=1 "$APP/Contents/MacOS/Overboard" &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT
sleep 3 # launch + demo seeding

notify() {
  swift -e "import Foundation
DistributedNotificationCenter.default().postNotificationName(
  .init(\"$NOTE\"), object: \"$1\", userInfo: nil, deliverImmediately: true)"
}

window_id() {
  swift -e 'import CoreGraphics
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "Overboard"
    && (w["kCGWindowLayer"] as? Int) == 101 { // NSWindow.Level.popUpMenu
    print(w["kCGWindowNumber"] as! Int)
    break
}'
}

shot() { # shot <name> <settle-seconds> <commands...>
  local name=$1 settle=$2
  shift 2
  echo "Capturing $name…"
  notify show
  sleep 1.5 # card entrance animation
  for cmd in "$@"; do
    notify "$cmd"
    sleep 0.3
  done
  sleep "$settle"
  local id
  id=$(window_id)
  if [ -z "$id" ]; then
    echo "error: demo panel window not found on screen" >&2
    exit 1
  fi
  screencapture -x -o -l "$id" "$OUT/$name.png"
  notify hide
  sleep 0.5
}

lshot() { # lshot <name> <settle-seconds> <query>
  local name=$1 settle=$2 query=$3
  echo "Capturing $name…"
  notify launcher-show
  sleep 0.8
  notify "launcher-query:$query"
  sleep "$settle" # 250ms debounce + row arrival
  local id
  id=$(window_id)
  if [ -z "$id" ]; then
    echo "error: launcher panel window not found on screen" >&2
    exit 1
  fi
  screencapture -x -o -l "$id" "$OUT/$name.png"
  notify launcher-hide
  sleep 0.5
}

shot drawer 0.2
shot preview 1.5 next preview
shot palette 1.0 next next next next palette
shot multiselect 1.0 stack stack extend extend
shot markdown 1.5 next next next next next next next next next preview
# Launcher shots: calculator, app search via initials, demo-seeded files
# (demo mode swaps the Spotlight file provider for DemoSeed.LauncherFiles,
# so no real home-folder paths can appear; app rows scan /Applications).
lshot launcher-calc 0.8 "15% of 80"
lshot launcher-apps 1.2 "sm"
lshot launcher-files 1.2 "release"
# "standup" matches both a seeded snippet and a seeded clip, so one frame
# shows both row kinds with their Clipboard/Snippet source badges.
lshot launcher-clips 1.2 "standup"

echo "Wrote:"
ls -la "$OUT"/*.png
