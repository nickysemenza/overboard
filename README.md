# Overboard ⛵️

[![CI](https://github.com/nickysemenza/overboard/actions/workflows/ci.yml/badge.svg)](https://github.com/nickysemenza/overboard/actions/workflows/ci.yml)

Everything you copy goes overboard. A native macOS clipboard manager — a personal,
better Paste: clipboard history, a bottom-drawer picker on a hotkey, instant
full-text search, and paste-back into whatever app you were using.

<p align="center">
  <img src="docs/screenshots/drawer.png" width="900" alt="The Overboard drawer: a search bar over a strip of clipboard cards — pinned note, syntax-highlighted code, link, image, JSON, files, color swatch, and a masked secret">
</p>

## Status

Feature-complete against the original roadmap and daily-driven by its author.
It's a personal tool first — issues and PRs are welcome, but it tracks one
person's workflow and taste.

## Install

Grab the zip from
[Releases](https://github.com/nickysemenza/overboard/releases) — it's
unsigned (no paid Developer Program behind this project), so the first launch
needs **right-click → Open**. Or build from source (macOS 14+, Xcode 16+):

```sh
git clone https://github.com/nickysemenza/overboard && cd overboard
xcodebuild -project Overboard.xcodeproj -scheme Overboard \
  -configuration Release -derivedDataPath build build
open build/Build/Products/Release   # drag Overboard.app to /Applications
```

Building from source signs with *your* Apple Development identity — set your
team in Xcode's Signing settings, or pass `CODE_SIGNING_ALLOWED=NO` (see the
signing note below for the TCC consequences).

Overboard lives in the menu bar (no Dock icon). On first run, grant
**Accessibility** when prompted (System Settings → Privacy & Security) —
paste-back synthesizes ⌘V into the target app and falls back to copy-only
without it. Nothing ever leaves your machine: no network, no analytics, no
account.

## Features

- **Capture**: clipboard history for text, rich text, links, images, files,
  and colors, with content-hash dedupe and source-app attribution.
- **Drawer** (⌘⇧V): bottom overlay over any app that never steals focus.
  Type to search, ←/→ or ⌘1–9 to select, ↩ to paste, ⇧↩ plain text,
  ⌘P pin, ⌘⌫ delete, esc to dismiss. Drag cards out to other apps.
- **Launcher** (⌥Space): a Spotlight-style bar with an inline calculator
  (`15% of 80` → ↩ copies, ⌘↩ pastes the result), app launching with
  initials and custom aliases (`sm` matches Sublime Merge out of the box),
  clipboard-history and snippet rows (search operators work here too;
  ↩ pastes into the app you were in, ⌘↩ copies), Spotlight file search,
  and a web-search fallback row.
- **Search**: FTS5 full-text with prefix matching, blended with on-device
  semantic search (NLEmbedding) so "money projection" finds "quarterly
  revenue forecast". Filter operators: `kind:image`, `app:claude`,
  `category:code`. Nothing ever leaves the machine.
- **Quick Look & edit**: space (or ⌘Y) expands the drawer into a full-content
  preview — scroll long text, see images large, browse with ←/→. ⌘E edits
  the text inline before pasting (⌘↩ pastes the edited version).
- **OCR**: copied images and screenshots are text-recognized (Vision) and
  fully searchable by their contents — find that wifi-password screenshot
  by typing the network name.
- **Apple Intelligence** (macOS 26, on-device, optional): clips get short
  auto-generated titles and category badges (code, error, address, …), and
  the card menu gains AI transforms — summarize, fix grammar, make
  formal/casual, extract action items.
- **Paste-back**: synthesized ⌘V into the app you were in, then your previous
  clipboard is restored. Falls back to copy + HUD without Accessibility.
- **Paste stack**: ⌘↩ queues items in the drawer; ⌥⌘V pastes them one by one.
- **Snippets** (⌘/ in drawer): saved templates with `{date}` `{time}`
  `{datetime}` `{uuid}` `{clipboard}` placeholders, managed from the menu bar.
- **Transforms**: right-click → Paste Transformed (strip tracking params,
  trim, change case).
- **Privacy**: password managers and concealed/transient pasteboards are
  never captured; detected secrets (AWS keys, JWTs, API tokens, PEM keys,
  card numbers) are masked, unsearchable, and auto-expire; per-app
  plain-text paste rules for terminals.

<p align="center">
  <img src="docs/screenshots/preview.png" width="900" alt="Quick Look preview pane showing a syntax-highlighted Swift snippet">
  <br><em>Quick Look (space): full-content preview with syntax highlighting</em>
</p>

<p align="center">
  <img src="docs/screenshots/palette.png" width="900" alt="⌘K action palette over a JSON clip, offering Pretty-Print JSON, Word Count, and Sum the Numbers">
  <br><em>⌘K action palette: transforms that match the selected clip</em>
</p>

<p align="center">
  <img src="docs/screenshots/multiselect.png" width="900" alt="Three cards multi-selected with a Stack: 2 badge in the search bar">
  <br><em>Multi-select (⇧→) and the paste stack (⌘↩ to queue, ⌥⌘V to paste one by one)</em>
</p>

<p align="center">
  <img src="docs/screenshots/launcher-apps.png" width="640" alt="The launcher bar: typing sm matches Sublime Merge by its initials, with open / reveal / copy path hints">
  <br><em>Launcher (⌥Space): apps match by name, initials, or your aliases</em>
</p>

<p align="center">
  <img src="docs/screenshots/launcher-calc.png" width="640" alt="The launcher evaluating 15% of 80 to 12 inline">
  <br><em>Inline calculator: ↩ copies the result, ⌘↩ pastes it into the app you were in</em>
</p>

<p align="center">
  <img src="docs/screenshots/launcher-clips.png" width="640" alt="The launcher matching a saved snippet and a clipboard item for the query standup, each marked with a Snippet or Clipboard source badge">
  <br><em>Clipboard history and snippets in the launcher, marked with source badges</em>
</p>

## Architecture

- `Overboard/` — thin app shell (menu-bar-only app, `LSUIElement`).
- `OverboardKit/` — local Swift package with almost all code:
  - `OverboardCore` — models, GRDB persistence, FTS5 search, capture pipeline.
    Foundation + GRDB only; reusable on iOS someday.
  - `OverboardMac` — the only module allowed to touch `NSPasteboard`,
    `NSWorkspace`, and `CGEvent`. Clipboard monitor, paste-back, permissions.
  - `OverboardUI` — SwiftUI overlay drawer, settings, onboarding.

Dependencies: [GRDB](https://github.com/groue/GRDB.swift),
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts),
[Highlightr](https://github.com/raspu/Highlightr),
[Expression](https://github.com/nicklockwood/Expression),
[Defaults](https://github.com/sindresorhus/Defaults),
[MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui), and
[swift-async-algorithms](https://github.com/apple/swift-async-algorithms).
Dev/test only: [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing),
SwiftFormat, and SwiftLint.

## Development notes

### Signing & Accessibility (read this before debugging paste-back)

macOS TCC keys the Accessibility grant to the app's code signature. The project
signs with a stable Apple Development identity (automatic signing, team
`HDPU3NY6TJ`). If you build with a different identity or ad-hoc signing, you'll
have to re-grant Accessibility after every build and paste-back will look
"flaky" — it isn't; it's TCC.

### Building

```sh
xcodebuild -project Overboard.xcodeproj -scheme Overboard build   # app
cd OverboardKit && swift test                                     # core tests
```

### Headless debug hooks (DEBUG builds only)

The overlay is scriptable via distributed notifications, so you can drive it
without the hotkey:

```sh
swift -e 'import Foundation; DistributedNotificationCenter.default()
  .postNotificationName(.init("com.nickysemenza.overboard.debug"),
  object: "show", userInfo: nil, deliverImmediately: true)'
```

Commands: `show`, `hide`, `toggle`, `commit`, `commit-plain`, `pin`, `delete`,
`preview`, `next`, `prev`, `extend`, `palette`, `stack`, plus the launcher's
`launcher-show`, `launcher-hide`, `launcher-toggle`, `launcher-query:<text>`,
`launcher-next`, `launcher-prev`, `launcher-commit`, `launcher-commit-cmd`,
`launcher-commit-opt`.
Traces append to `/tmp/overboard-trace.log` via `obTrace(_:)`.

### Regenerating the README screenshots

```sh
./scripts/demo-screenshots.sh
```

Launches the app with `OVERBOARD_DEMO=1` (in-memory store seeded by
`DemoSeed.swift` — no real clipboard data), drives it over the
`com.nickysemenza.overboard.demo` notification, and captures the panel into
`docs/screenshots/`. Quit the daily-driver instance first; the terminal needs
Screen Recording permission.

### Manual smoke checklist (run before calling a milestone done)

- [ ] Copy plain text, rich text, an image, and a file in different apps →
      each appears in history with the right kind and source app icon.
- [ ] Copy the same text twice → one row, bumped to the top.
- [ ] Copy in a password field and from 1Password → nothing is captured.
- [ ] Quit and relaunch → history persists.
- [ ] Summon the drawer (⌘⇧V) over a TextEdit document → the drawer appears and
      the document's cursor **keeps blinking** (no focus steal).
- [ ] Type while the drawer is open → search filters; Esc dismisses instantly.
- [ ] Return pastes into TextEdit, Safari's URL bar, Slack, and a terminal.
- [ ] With "restore clipboard" on → after paste-back, the previous clipboard
      contents are back and history isn't polluted.
- [ ] Activity Monitor: ~0% CPU idle, memory flat with images in history.

### Cutting a release

```sh
git tag v1.0.0 && git push --tags
```

The Release workflow builds the unsigned zip and attaches it to a GitHub
Release. `./scripts/release.sh 1.0.0` produces the same zip locally into
`dist/`.

## License

[MIT](LICENSE)
