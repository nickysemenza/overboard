import AppKit
import OverboardCore
import SwiftUI
import UniformTypeIdentifiers

public struct LauncherView: View {
    @Bindable var viewModel: LauncherViewModel
    let store: ClipStore
    @FocusState private var fieldFocused: Bool

    public init(viewModel: LauncherViewModel, store: ClipStore) {
        self.viewModel = viewModel
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 8) {
            self.searchBar
            if !self.viewModel.results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    // Per-run section headers from `annotate`; the flat index
                    // stays the selection key, headers are purely decorative.
                    ForEach(
                        Array(LauncherSection.annotate(self.viewModel.results).enumerated()),
                        id: \.element.result.id
                    ) { index, row in
                        if let header = row.header {
                            LauncherSectionHeader(title: header)
                        }
                        LauncherRow(result: row.result, store: self.store, isSelected: index == self.viewModel.selectedIndex)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture {
                                self.viewModel.selectedIndex = index
                                self.viewModel.commit()
                            }
                    }
                }
                // Rows stream in (instant, then debounced) while the panel
                // resizes; animating insertions left ghost frames of the rows
                // (and their image thumbnails) mid-reflow.
                .transaction { $0.disablesAnimations = true }
                // Hard-clip so nothing (a loading thumbnail, a row mid-reflow)
                // can paint outside the list bounds.
                .clipped()
            }
            // Persistent action bar — present even with zero rows, so the panel
            // always advertises the ⌘K palette and the selected row's primary
            // action. The row hints and source badges that used to live per-row
            // now live here (plus in the section headers).
            Divider()
            LauncherFooterBar(primaryAction: self.viewModel.primaryAction)
        }
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
            if self.viewModel.isPaletteOpen {
                LauncherActionPalette(viewModel: self.viewModel)
                    .padding(.bottom, 18)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: self.viewModel.isPaletteOpen)
        .padding(12)
        .onAppear {
            self.fieldFocused = true
        }
        .onChange(of: self.viewModel.showGeneration) {
            self.fieldFocused = true
        }
        .onChange(of: self.viewModel.query) {
            self.viewModel.scheduleSearch()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.secondary)
            TextField("Calculate, search clips, files, the web…", text: self.$viewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(self.$fieldFocused)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }
}

/// Section label above the first row of each provider run ("Apps", "Files",
/// "Recent", …). Panel height budgets `Metrics.headerHeight` per header, so
/// keep this in sync with LauncherPanelController if the styling changes.
struct LauncherSectionHeader: View {
    let title: String

    var body: some View {
        Text(self.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 2)
    }
}

/// Persistent bottom action bar. Left brands the panel; right shows the
/// selected row's primary (↩) action and the ⌘K palette affordance. Rendered
/// whenever the panel is visible — even with no results — so the bar height is
/// always budgeted (`Metrics.footerHeight`).
struct LauncherFooterBar: View {
    let primaryAction: LauncherAction?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.caption)
            Text("Overboard")
                .font(.caption)
            Spacer(minLength: 12)
            if let primaryAction {
                Text(primaryAction.label)
                    .font(.caption)
                Image(systemName: "return")
                    .font(.caption2)
                Divider()
                    .frame(height: 12)
            }
            Text("Actions")
                .font(.caption)
            Text("⌘K")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
    }
}

struct LauncherRow: View {
    let result: LauncherResult
    let store: ClipStore
    let isSelected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            self.icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.title)
                    .font(.body.weight(self.titleWeight))
                    .lineLimit(1)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            // The footer bar + ⌘K palette + section headers now carry the
            // per-row hints and source labels; only the Spotify badge stays,
            // since now-playing rows have no section header to place them under.
            if let badge = self.sourceBadge {
                HStack(spacing: 3) {
                    Image(systemName: badge.symbol)
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
        .padding(.vertical, 6)
        .background(
            self.isSelected ? Color.accentColor.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: self.result.id) {
            await self.loadThumbnailIfNeeded()
        }
    }

    @ViewBuilder private var icon: some View {
        switch self.result {
        case .calculation:
            Image(systemName: "equal.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case let .app(_, url), let .file(_, url):
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
                Image(systemName: Self.kindSymbol(for: item.kind))
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
        case let .clip(item): Self.clipTitle(for: item)
        case let .file(name, _): name
        case let .webSearch(query, _): "Search Google for “\(query)”"
        case let .systemSetting(name, _): name
        case let .command(command, _): command.title
        case let .recentSearch(query): query
        case let .nowPlaying(track): track.title
        }
    }

    private var titleWeight: Font.Weight {
        if case .calculation = self.result { .semibold } else { .regular }
    }

    private var subtitle: String {
        switch self.result {
        case let .calculation(input, _): "\(input.trimmingCharacters(in: .whitespaces)) ="
        case .app: "Application"
        case let .snippet(snippet): Self.firstLine(of: snippet.body) ?? "Snippet"
        case let .clip(item): Self.clipSubtitle(for: item)
        case let .file(_, url): (url.path as NSString).abbreviatingWithTildeInPath
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
        if FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
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
            ?? self.kindLabel(for: item.kind)
    }

    private static func clipSubtitle(for item: ClipItem) -> String {
        let when = item.lastUsedAt.formatted(.relative(presentation: .named))
        guard let app = item.sourceAppName else { return when }
        return "\(app) · \(when)"
    }

    private static func firstLine(of text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespaces)
        return (line?.isEmpty ?? true) ? nil : line
    }

    private static func kindSymbol(for kind: ItemKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }

    private static func kindLabel(for kind: ItemKind) -> String {
        switch kind {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }
}
