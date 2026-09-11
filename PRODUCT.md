# Overboard

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS 26+, SwiftUI and AppKit.

## Users and purpose

A personal, keyboard-driven launcher and clipboard manager. The primary jobs are finding local and iCloud Drive files by name or path, retrieving clipboard history, searching Google, and opening apps. Calculator, snippets, system commands, Apple Intelligence, and now playing remain part of the launcher.

## Product principles

- Enter always activates the selected result; the first result is selected by default.
- Match quality outranks provider order. Successful use improves ranking within a match tier.
- All mixes results; Files, Clipboard, and Apps provide focused scopes.
- The empty launcher suggests apps using frequency and recency of successful actions through Overboard; running apps provide an initial fallback.
- Keep the bottom clipboard drawer for recent pastes and a list with preview for browsing history.
- Search and indexing read file metadata, not file contents. Opening an undownloaded cloud file is an explicit action.
- Preserve source-app targeting, clipboard restoration, and secret-handling rules.

## Design commitments

Refine the existing native macOS visual system: system typography, restrained glass, clear selection, readable filenames and breadcrumbs, content-led previews, and an unobscured action footer. Support system appearance, reduced motion and transparency, and keyboard accessibility.

## Boundaries

Filename/path search includes accessible user folders, iCloud Drive and Finder-visible cloud folders. Document-content search and dedicated NAS indexing are deferred. Cloud search covers metadata exposed to macOS.
