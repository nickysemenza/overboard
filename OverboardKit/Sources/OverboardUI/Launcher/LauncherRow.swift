import AppKit
import OverboardCore
import OverboardMac
import SwiftUI
import UniformTypeIdentifiers

struct LauncherRow: View {
    let result: LauncherResult
    let store: ClipStore
    let isSelected: Bool
    let runningAppPaths: Set<String>
    var query: String = ""
    var showsSourceBadge = true
    /// FTS match excerpt for a `.clip` row, computed once per search pass in
    /// `LauncherViewModel.matchExcerpts` (batched into one store call) rather
    /// than fetched here per row.
    var excerpt: String?
    /// Actions this row can perform, in footer/palette order — surfaced as
    /// VoiceOver accessibility actions so a row can be operated without first
    /// becoming the keyboard selection.
    var actions: [LauncherAction] = []
    /// A single click selects the row.
    var onSelect: () -> Void = {}
    /// A double click selects and immediately commits (the row's primary
    /// action), mirroring plain ↩ on an already-selected row.
    var onCommit: () -> Void = {}
    var onPerformAction: (LauncherAction) -> Void = { _ in }
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: self.onSelect) {
            HStack(spacing: 10) {
                self.icon
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .bottomTrailing) {
                        if case let .app(_, url) = self.result, self.runningAppPaths.contains(url.path) {
                            Circle()
                                .fill(.secondary)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    SearchHighlightedText(text: self.title, query: self.query)
                        .font(.body.weight(self.titleWeight))
                        .lineLimit(1)
                    SearchHighlightedText(text: self.subtitle, query: self.query)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                // The footer bar + ⌘K palette + section headers now carry the
                // per-row hints and source labels; only the Spotify badge stays,
                // since now-playing rows have no section header to place them under.
                if case let .clip(item) = self.result, item.isPinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
                if case let .file(_, _, info) = self.result, info.availability != .local {
                    Image(systemName: info.availability == .unavailable ? "exclamationmark.icloud" : "icloud.and.arrow.down")
                        .foregroundStyle(.secondary).help(info.availability == .unavailable ? "Unavailable" : "In the cloud")
                }
                if self.showsSourceBadge, let badge = self.sourceBadge {
                    HStack(spacing: 3) {
                        Image(systemName: badge.symbol)
                            .accessibilityHidden(true)
                        Text(badge.label)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(LauncherRowButtonStyle(isSelected: self.isSelected))
        // Plain ↩-style commit on a double click; the single click above
        // still selects independently of this.
        .simultaneousGesture(TapGesture(count: 2).onEnded(self.onCommit))
        .task(id: self.result.id) {
            await self.loadThumbnailIfNeeded()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(self.title), \(self.subtitle)", bundle: .module))
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
        .accessibilityActions {
            ForEach(self.actions) { action in
                Button(action.label) { self.onPerformAction(action) }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch self.result {
        case .calculation:
            Image(systemName: "equal.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case let .file(_, _, info) where info.isDirectory:
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(.blue)
        case let .app(_, url), let .file(_, url, _):
            Image(nsImage: Self.fileIcon(for: url))
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .snippet:
            Image(systemName: "text.badge.star")
                .font(.title2)
                .foregroundStyle(.purple)
        case let .clip(item):
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Constrain to the icon slot *before* clipping — without the
                    // explicit frame the full-size thumbnail briefly painted
                    // outside the row (the lower-left ghost cards).
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let appIcon = AppIconCache.shared.icon(forBundleID: item.sourceBundleID) {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        case .webSearch:
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
        case .systemSetting:
            Image(systemName: "gearshape.fill")
                .font(.title2)
                .foregroundStyle(.gray)
        case let .command(command, _):
            Image(systemName: Self.commandSymbol(for: command))
                .font(.title2)
                .foregroundStyle(.teal)
        case .recentSearch:
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.secondary)
        case let .nowPlaying(track):
            Image(systemName: track.state == .playing ? "music.note" : "pause.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .askAI:
            // Sparkles in the purple/accent tint the AI ✨ transforms use.
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.purple)
        }
    }

    /// Image clips show the actual picture instead of the source-app icon,
    /// same payload + downscale path as the drawer cards.
    private func loadThumbnailIfNeeded() async {
        guard case let .clip(item) = self.result, item.kind == .image else {
            self.thumbnail = nil
            return
        }
        guard let rep = try? await store.representations(for: item.id)
            .first(where: { $0.uti == WellKnownUTI.png }),
            let data = try? await store.payload(for: rep)
        else { return }
        // 2× the 28 pt frame so Retina stays sharp.
        self.thumbnail = ItemCardView.thumbnail(from: data, maxPixel: 64)
    }

    private var title: String {
        switch self.result {
        case let .calculation(_, display): display
        case let .app(name, _): name
        case let .snippet(snippet): snippet.title
        case let .clip(item): self.excerpt ?? Self.clipTitle(for: item)
        case let .file(name, _, _): name
        case let .webSearch(query, _): String(localized: "Search Google for “\(query)”", bundle: .module)
        case let .systemSetting(name, _): name
        case let .command(command, _): command.title
        case let .recentSearch(query): query
        case let .nowPlaying(track): track.title
        case let .askAI(prompt): String(localized: "Ask AI: “\(prompt)”", bundle: .module)
        }
    }

    private var titleWeight: Font.Weight {
        if case .calculation = self.result { .semibold } else { .regular }
    }

    private var subtitle: String {
        switch self.result {
        case let .calculation(input, _): String(localized: "\(input.trimmingCharacters(in: .whitespaces)) =", bundle: .module)
        case .app: "Application"
        case let .snippet(snippet): Self.firstLine(of: snippet.body) ?? "Snippet"
        case let .clip(item): Self.clipSubtitle(for: item)
        case let .file(_, url, _): FileBreadcrumb.label(url.deletingLastPathComponent())
        case .webSearch: "Open in browser"
        case .systemSetting: "System Settings"
        // The provider's resolved subtitle wins (the live :stats count);
        // otherwise the command's static one.
        case let .command(command, subtitle): subtitle ?? command.subtitle
        case .recentSearch: "Recent search"
        case let .nowPlaying(track):
            track.artist.isEmpty
                ? (track.state == .playing ? "Now playing" : "Paused")
                : "\(track.artist) · \(track.state == .playing ? "Now playing" : "Paused")"
        case .askAI: "Runs on your current clipboard text"
        }
    }

    /// SF Symbol per launcher command — matched to what the command does so the
    /// row reads at a glance.
    private static func commandSymbol(for command: LauncherCommand) -> String {
        switch command {
        case .version: "info.circle.fill"
        case .stats: "chart.bar.fill"
        case .pause: "pause.circle.fill"
        case .resume: "play.circle.fill"
        case .clear: "trash.fill"
        case .settings: "gearshape.fill"
        }
    }

    /// Missing paths (demo mode's fake files) get their file-type icon
    /// instead of the blank generic-document one.
    private static func fileIcon(for url: URL) -> NSImage {
        // Generic type icons are metadata-only; probing a dataless file or
        // requesting a Quick Look thumbnail here can trigger a download.
        if url.pathExtension == "app" { return NSWorkspace.shared.icon(forFile: url.path) }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// Only the now-playing row keeps a trailing badge: it's the one row kind
    /// with no section header above it, so the "Spotify" label is what marks it
    /// as music rather than a plain clip. Snippet/Clipboard badges moved to the
    /// section headers + footer.
    private var sourceBadge: (symbol: String, label: String)? {
        switch self.result {
        case .nowPlaying: (symbol: "music.note", label: "Spotify")
        default: nil
        }
    }

    // MARK: - Clip row helpers

    private static func clipTitle(for item: ClipItem) -> String {
        item.aiTitle
            ?? self.firstLine(of: item.previewText ?? "")
            ?? item.kind.displayName
    }

    private static func clipSubtitle(for item: ClipItem) -> String {
        let when = item.lastUsedAt.formatted(.relative(presentation: .named))
        guard let app = item.sourceAppName else { return when }
        return String(localized: "\(app) · \(when)", bundle: .module)
    }

    private static func firstLine(of text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespaces)
        return (line?.isEmpty ?? true) ? nil : line
    }
}

#if DEBUG
    #Preview("Row: Calculation") {
        LauncherRow(
            result: .calculation(input: "12*4", display: "48"),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: App") {
        LauncherRow(
            result: .app(name: "Demo App", url: URL(fileURLWithPath: "/Applications/OverboardDemo.app")),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Snippet") {
        LauncherRow(
            result: .snippet(Snippet(title: "Standup update", body: "Yesterday: shipped X.")),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Clip") {
        LauncherRow(
            result: .clip(Fixtures.item(preview: "deploy checklist")),
            store: try! Fixtures.store(),
            isSelected: true,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: File") {
        LauncherRow(
            result: .file(name: "notes.md", url: URL(fileURLWithPath: "/tmp/overboard-missing/notes.md")),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Web search") {
        LauncherRow(
            result: .webSearch(query: "swiftui previews", url: URL(string: "https://www.google.com/search?q=swiftui+previews")!),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: System setting") {
        LauncherRow(
            result: .systemSetting(
                name: "Displays",
                url: URL(string: "x-apple.systempreferences:com.apple.preference.displays")!
            ),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Command") {
        LauncherRow(
            result: .command(.stats, subtitle: "128 items"),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Recent search") {
        LauncherRow(
            result: .recentSearch(query: "deploy checklist"),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Now playing") {
        LauncherRow(
            result: .nowPlaying(
                NowPlayingTrack(title: "Song Title", artist: "The Artist", trackID: "spotify:track:6rqhFgbbKwnb9MLmUQDhG6", state: .playing)
            ),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Ask AI") {
        LauncherRow(
            result: .askAI(prompt: "Summarize this"),
            store: try! Fixtures.store(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }
#endif
