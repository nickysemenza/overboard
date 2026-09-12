import AppKit
import OverboardCore
import OverboardMac
import SwiftUI
import UniformTypeIdentifiers

/// THESIS: Make the selected result recognizable and its action predictable.
/// OWN-WORLD: macOS system type, native icons, restrained glass, one accent selection.
/// STORY: Type, recognize the result, inspect when useful, press Return.
/// FIRST VIEWPORT: Search and scopes above a bounded list; adjacent preview on
/// demand; primary action in a reserved footer that never overlaps results.
/// FORM: User-approved compact launcher plus list/detail clipboard browser;
/// an extension of the existing native design, not a new visual-world selection.
/// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md
public struct LauncherView: View {
    @Bindable var viewModel: LauncherViewModel
    let store: ClipStore
    @FocusState private var fieldFocused: Bool

    public init(viewModel: LauncherViewModel, store: ClipStore) {
        self.viewModel = viewModel
        self.store = store
    }

    public var body: some View {
        Group {
            VStack(spacing: 0) {
                self.searchBar
                self.scopeBar
                if self.viewModel.scope == .clipboard { self.clipboardFilters }
                Divider()
                HStack(spacing: 0) {
                    self.resultList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if self.viewModel.showsPreview {
                        Divider()
                        LauncherPreview(result: self.viewModel.selectedResult, store: self.store, query: self.viewModel.query,
                                        onOpen: { self.viewModel.commit() })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let message = self.viewModel.statusMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
                Divider()
                LauncherFooterBar(primaryAction: self.viewModel.primaryAction, label: self.viewModel.primaryActionLabel,
                                  onCommit: { self.viewModel.commit() }, onActions: { self.viewModel.togglePalette() })
                    .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .glassPanel(cornerRadius: 18)
            .overlay(alignment: .bottom) {
                if self.viewModel.isPaletteOpen {
                    LauncherActionPalette(viewModel: self.viewModel)
                        .padding(.bottom, 46)
                }
            }
            .padding(12)
            .onAppear { self.fieldFocused = true }
            .onChange(of: self.viewModel.showGeneration) { self.fieldFocused = true }
            .onChange(of: self.viewModel.scope) { self.fieldFocused = true }
            .onChange(of: self.viewModel.isPaletteOpen) {
                if !self.viewModel.isPaletteOpen { self.fieldFocused = true }
            }
            .onChange(of: self.viewModel.query) { self.viewModel.scheduleSearch() }
            .onChange(of: self.viewModel.clipboardFilter) { self.viewModel.scheduleSearch() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
            TextField(self.viewModel.scope == .clipboard ? "Find something you copied…" : "Search apps, files, clipboard, or the web…", text: self.$viewModel.query)
                .textFieldStyle(.plain).font(.system(size: 20)).focused(self.$fieldFocused)
                .accessibilityLabel("Search \(self.viewModel.scope.rawValue)")
            if self.viewModel.isSearching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20).frame(height: 62)
    }

    private var scopeBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(LauncherScope.allCases.enumerated()), id: \.element) { index, scope in
                Button { self.viewModel.setScope(scope) } label: {
                    HStack(spacing: 6) {
                        Text(scope.rawValue).font(.system(size: 12, weight: .medium))
                        Text("⌘\(index + 1)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(self.viewModel.scope == scope ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(self.viewModel.scope == scope ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if self.viewModel.scope == .files {
                Text(FileIndexService.shared.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var clipboardFilters: some View {
        HStack(spacing: 8) {
            Picker("Type", selection: self.$viewModel.clipboardFilter.kind) {
                Text("All types").tag(ItemKind?.none)
                ForEach(ItemKind.allCases, id: \.self) { kind in Text(kind.displayName).tag(Optional(kind)) }
            }
            Picker("Source", selection: self.$viewModel.clipboardFilter.source) {
                Text("All apps").tag(String?.none)
                ForEach(self.viewModel.sources, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker("Copied", selection: self.$viewModel.clipboardFilter.period) {
                ForEach(ClipboardFilter.Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle(isOn: self.$viewModel.clipboardFilter.pinnedOnly) {
                Image(systemName: "pin").accessibilityLabel("Pinned only")
            }.toggleStyle(.button).help("Pinned only")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .labelsHidden().controlSize(.small).padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if self.viewModel.results.isEmpty {
                        ContentUnavailableView(self.viewModel.isSearching ? "Searching…" : "No results", systemImage: self.viewModel.scope == .clipboard ? "doc.on.clipboard" : "magnifyingglass",
                                               description: Text(self.viewModel.scope == .clipboard ? "Copy something, or try a different search or filter." : "Try a shorter name or choose another scope."))
                            .frame(maxWidth: .infinity, minHeight: 140)
                    }
                    ForEach(Array(self.viewModel.results.enumerated()), id: \.element.id) { index, result in
                        if let header = self.historyHeader(at: index) {
                            Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                        }
                        LauncherRow(result: result, store: self.store, isSelected: index == self.viewModel.selectedIndex,
                                    runningAppPaths: self.viewModel.runningAppPaths, query: self.viewModel.query,
                                    showsSourceBadge: self.viewModel.scope != .clipboard)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { self.viewModel.select(at: index); self.viewModel.commit() }
                            .onTapGesture { self.viewModel.select(at: index) }
                            .id(result.id)
                    }
                    if self.viewModel.hasMoreClipboard {
                        Button("Show more history", action: self.viewModel.loadMoreClipboard)
                            .buttonStyle(.plain).font(.caption).padding(12)
                    }
                }
                .padding(8)
            }
            .onChange(of: self.viewModel.selectedResult?.id) {
                if let id = self.viewModel.selectedResult?.id { proxy.scrollTo(id) }
            }
            .onChange(of: self.viewModel.results.count) {
                if let id = self.viewModel.selectedResult?.id { proxy.scrollTo(id) }
            }
        }
    }

    private func historyHeader(at index: Int) -> String? {
        if self.viewModel.scope == .all, self.viewModel.query.isEmpty {
            switch self.viewModel.results[index] {
            case .app: return index == 0 ? "Suggestions" : nil
            case .recentSearch:
                if index > 0, case .recentSearch = self.viewModel.results[index - 1] { return nil }
                return "Recent searches"
            default: return nil
            }
        }
        guard self.viewModel.scope == .clipboard, self.viewModel.query.isEmpty,
              case let .clip(item) = self.viewModel.results[index] else { return nil }
        func label(_ date: Date) -> String {
            if Calendar.current.isDateInToday(date) { return "Today" }
            if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let title = label(item.lastUsedAt)
        if index > 0, case let .clip(previous) = self.viewModel.results[index - 1], label(previous.lastUsedAt) == title { return nil }
        return title
    }
}

/// Section label above the first row of each provider run ("Apps", "Files",
/// "Recent", …). Headers share the scrolling result viewport.
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
/// whenever the panel is visible — even with no results — in dedicated space.
struct LauncherFooterBar: View {
    let primaryAction: LauncherAction?
    var label: String?
    var onCommit: () -> Void = {}
    var onActions: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.caption)
            Text("Overboard")
                .font(.caption)
            Spacer(minLength: 12)
            if let primaryAction {
                Button(self.label ?? primaryAction.label, action: self.onCommit)
                    .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.primary)
                Image(systemName: "return")
                    .font(.caption2)
                Divider()
                    .frame(height: 12)
            }
            Button("Actions", action: self.onActions)
                .buttonStyle(.plain).font(.caption)
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
    let runningAppPaths: Set<String>
    var query: String = ""
    var showsSourceBadge = true
    @State private var thumbnail: NSImage?
    @State private var excerpt: String?

    var body: some View {
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
                    .font(.caption)
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
        .background(
            self.isSelected ? Color.accentColor.opacity(0.20) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: self.result.id + self.query) {
            self.excerpt = nil
            if case let .clip(item) = self.result, !self.query.isEmpty {
                let excerpt = try? await self.store.matchExcerpt(itemID: item.id, query: self.query)
                guard !Task.isCancelled else { return }
                self.excerpt = excerpt
            }
            await self.loadThumbnailIfNeeded()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.title), \(self.subtitle)")
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
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
        case let .webSearch(query, _): "Search Google for “\(query)”"
        case let .systemSetting(name, _): name
        case let .command(command, _): command.title
        case let .recentSearch(query): query
        case let .nowPlaying(track): track.title
        case let .askAI(prompt): "Ask AI: “\(prompt)”"
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
        case .app: (symbol: "app", label: "App")
        case .file: (symbol: "doc", label: "File")
        case .clip: (symbol: "doc.on.clipboard", label: "Clipboard")
        case .snippet: (symbol: "text.badge.star", label: "Snippet")
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

#if DEBUG
    #Preview("Sections") {
        let viewModel = LauncherViewModel(
            instantProviders: [StubLauncherProvider(rows: [
                .app(name: "Demo App", url: URL(fileURLWithPath: "/Applications/OverboardDemo.app")),
                .clip(Fixtures.item(preview: "deploy checklist")),
                .file(name: "notes.md", url: URL(fileURLWithPath: "/tmp/overboard-missing/notes.md")),
            ])],
            secondaryProviders: []
        )
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        return LauncherView(viewModel: viewModel, store: try! Fixtures.store())
            .frame(width: 640, height: 370)
    }

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

    #Preview("Section header") {
        LauncherSectionHeader(title: "Apps")
            .padding()
            .frame(width: 300)
    }

    #Preview("Footer bar") {
        LauncherFooterBar(primaryAction: .open)
            .padding()
            .frame(width: 400)
    }
#endif
