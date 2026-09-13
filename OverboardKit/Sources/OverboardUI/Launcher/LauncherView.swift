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
/// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and
/// DESIGN.md
public struct LauncherView: View {
    @Bindable var viewModel: LauncherViewModel
    let store: ClipStore
    @FocusState private var fieldFocused: Bool

    public init(viewModel: LauncherViewModel, store: ClipStore) {
        self.viewModel = viewModel
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            LauncherSearchBar(viewModel: self.viewModel, fieldFocused: self.$fieldFocused)
            LauncherScopeBar(viewModel: self.viewModel)
            if self.viewModel.scope == .clipboard {
                self.clipboardFilters
            }
            Divider()
            HStack(spacing: 0) {
                LauncherResultList(viewModel: self.viewModel, store: self.store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if self.viewModel.showsPreview {
                    Divider()
                    LauncherPreview(
                        result: self.viewModel.selectedResult,
                        store: self.store,
                        query: self.viewModel.query,
                        onOpen: { self.viewModel.commit() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Overlaying just the list/preview region — rather than the
            // whole panel with a hand-tuned bottom padding to clear the
            // footer's height — anchors the palette to this region's own
            // bottom edge, which already sits directly above the (optional)
            // error banner, the divider, and the footer.
            .overlay(alignment: .bottom) {
                if self.viewModel.isPaletteOpen {
                    LauncherActionPalette(viewModel: self.viewModel)
                        .padding(.bottom, 8)
                }
            }
            if let message = self.viewModel.statusMessage {
                self.errorBanner(message)
            }
            Divider()
            LauncherFooterBar(viewModel: self.viewModel)
        }
        .glassPanel(cornerRadius: PanelRadius.launcher)
        .padding(12)
        .onAppear { self.fieldFocused = true }
        .onChange(of: self.viewModel.showGeneration) { self.fieldFocused = true }
        .onChange(of: self.viewModel.scope) { self.fieldFocused = true }
        .onChange(of: self.viewModel.isPaletteOpen) {
            if !self.viewModel.isPaletteOpen {
                self.fieldFocused = true
            }
        }
        .onChange(of: self.viewModel.query) { self.viewModel.scheduleSearch() }
        .onChange(of: self.viewModel.clipboardFilter) { self.viewModel.scheduleSearch() }
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

    /// A store/search failure (e.g. clipboard FTS erroring out) gets a tinted,
    /// actionable banner instead of a faint secondary caption — DESIGN.md's
    /// "don't use faint text to solve density or hierarchy problems for
    /// actionable hints" applies here since Retry is a real recovery action.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
            Spacer(minLength: 8)
            Button("Retry") { self.viewModel.scheduleSearch(preserveSelection: true) }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
            Button {
                self.viewModel.statusMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: PanelRadius.palette))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

#if DEBUG
    #Preview("Sections") {
        let viewModel = LauncherViewModel(
            instantProviders: [
                StubLauncherProvider(rows: [
                    .app(name: "Demo App", url: URL(fileURLWithPath: "/Applications/OverboardDemo.app")),
                    .clip(Fixtures.item(preview: "deploy checklist")),
                    .file(name: "notes.md", url: URL(fileURLWithPath: "/tmp/overboard-missing/notes.md")),
                ]),
            ],
            secondaryProviders: []
        )
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        return LauncherView(viewModel: viewModel, store: Fixtures.previewStore())
            .frame(width: 640, height: 370)
    }

#endif
