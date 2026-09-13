import AppKit
import OverboardCore
import SwiftUI

/// Owns the launcher panel lifecycle: summon, position, key handling,
/// dismiss. Same shape as OverlayController, but centered Spotlight-style
/// and with a vertical-list keyboard model.
///
/// Split across extensions in this directory: `LauncherPanelController+Panel.swift`
/// (NSPanel/window sizing and positioning) and `LauncherPanelController+Keys.swift`
/// (keyboard event handling). A few stored properties below are `internal`
/// rather than `private` purely so those extensions can read/write them;
/// none of that widening reaches past this module's public API.
public final class LauncherPanelController {
    let viewModel: LauncherViewModel
    let store: ClipStore
    var panel: OverlayPanel?
    var keyMonitor: Any?
    var clickMonitor: Any?
    var resignObserver: NSObjectProtocol?

    /// When the launcher was last dismissed; reopening within `resumeWindow`
    /// resumes the previous text, otherwise the bar opens fresh.
    private var lastHiddenAt: Date?
    static let resumeWindow: TimeInterval = 10

    /// The app that was frontmost when the launcher was summoned — i.e.
    /// where a pasted calculator result should land.
    public private(set) var targetApp: NSRunningApplication?

    public var onCopyText: (String) -> Void = { _ in }
    public var onPasteText: (String, NSRunningApplication?) -> Void = { _, _ in }
    public var onOpenFile: (URL) -> Void = { _ in }
    public var onRevealFile: (URL) -> Void = { _ in }
    public var onCopyPath: (String) -> Void = { _ in }
    public var onOpenWebSearch: (URL) -> Void = { _ in }
    public var onOpenSystemSetting: (URL) -> Void = { _ in }
    public var onPasteClip: (ClipItem, PasteMode, NSRunningApplication?) -> Void = { _, _, _ in }
    public var onCopyClip: (ClipItem) -> Void = { _ in }
    public var onPasteSnippet: (Snippet, NSRunningApplication?) -> Void = { _, _ in }
    public var onCopySnippet: (Snippet) -> Void = { _ in }
    public var onRunCommand: (LauncherCommand) -> Void = { _ in }
    public var onCopyNowPlayingLink: (NowPlayingTrack) -> Void = { _ in }
    public var onOpenSpotify: (NowPlayingTrack) -> Void = { _ in }
    /// Run a free-text Apple Intelligence prompt over the clipboard text and
    /// deliver the result. Paste delivery needs the frontmost app captured
    /// before the panel hides, mirroring `onPasteClip`.
    public var onAskAI: (String, LauncherViewModel.AskAIDelivery, NSRunningApplication?) -> Void = { _, _, _ in }
    /// Quit a running app (⌘K → Quit); the URL is the app bundle's file URL.
    public var onQuitApp: (URL) -> Void = { _ in }
    /// Open a link clip's URL in the browser (⌘K → Open Link on a link clip).
    public var onOpenClipLink: (URL) -> Void = { _ in }
    /// Called as the launcher is summoned, before rows render — the hook that
    /// reconciles the Spotify now-playing snapshot so a missed notification is
    /// caught exactly when the stale row would otherwise be visible. Also
    /// refreshes the running-app snapshot behind the row indicator dots.
    public var onWillShow: () -> Void = {}
    /// Called as the launcher is dismissed (stops running-app observation).
    public var onWillHide: () -> Void = {}

    public init(store: ClipStore, viewModel: LauncherViewModel) {
        self.store = store
        self.viewModel = viewModel
        self.configureFileActions()
        self.configureClipActions()
        self.configureMiscActions()
    }

    /// Wires the callbacks whose completion is "hide the panel, then hand the
    /// file/text payload to the app layer". Split out of `init` (along with
    /// `configureClipActions`/`configureMiscActions` below) purely to keep
    /// each function's cyclomatic complexity down — every closure here is the
    /// same `guard let self else { return }` shape `init` used to repeat inline.
    private func configureFileActions() {
        self.viewModel.onCopyText = { [weak self] text in
            guard let self else { return }
            self.hide()
            self.onCopyText(text)
        }
        self.viewModel.onPasteText = { [weak self] text in
            guard let self else { return }
            let target = self.targetApp
            self.hide()
            self.onPasteText(text, target)
        }
        self.viewModel.onOpenFile = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onOpenFile(url)
        }
        self.viewModel.onRevealFile = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onRevealFile(url)
        }
        self.viewModel.onCopyPath = { [weak self] path in
            guard let self else { return }
            self.hide()
            self.onCopyPath(path)
        }
        self.viewModel.onOpenWebSearch = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onOpenWebSearch(url)
        }
    }

    /// See `configureFileActions`: the clipboard/snippet/command callbacks.
    private func configureClipActions() {
        self.viewModel.onOpenSystemSetting = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onOpenSystemSetting(url)
        }
        self.viewModel.onPasteClip = { [weak self] item, mode in
            guard let self else { return }
            // Capture before hide() — hiding clears targetApp.
            let target = self.targetApp
            self.hide()
            self.onPasteClip(item, mode, target)
        }
        self.viewModel.onCopyClip = { [weak self] item in
            guard let self else { return }
            self.hide()
            self.onCopyClip(item)
        }
        self.viewModel.onPasteSnippet = { [weak self] snippet in
            guard let self else { return }
            let target = self.targetApp
            self.hide()
            self.onPasteSnippet(snippet, target)
        }
        self.viewModel.onCopySnippet = { [weak self] snippet in
            guard let self else { return }
            self.hide()
            self.onCopySnippet(snippet)
        }
        self.viewModel.onRunCommand = { [weak self] command in
            guard let self else { return }
            self.hide()
            self.onRunCommand(command)
        }
    }

    /// See `configureFileActions`: now-playing/AI/app and layout callbacks.
    private func configureMiscActions() {
        self.viewModel.onCopyNowPlayingLink = { [weak self] track in
            guard let self else { return }
            self.hide()
            self.onCopyNowPlayingLink(track)
        }
        self.viewModel.onOpenSpotify = { [weak self] track in
            guard let self else { return }
            self.hide()
            self.onOpenSpotify(track)
        }
        self.viewModel.onAskAI = { [weak self] prompt, delivery in
            guard let self else { return }
            // Capture before hide() — hiding clears targetApp — so a pasted
            // result lands in the app that was frontmost when we were summoned.
            let target = self.targetApp
            self.hide()
            self.onAskAI(prompt, delivery, target)
        }
        self.viewModel.onQuitApp = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onQuitApp(url)
        }
        self.viewModel.onOpenClipLink = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onOpenClipLink(url)
        }
        self.viewModel.onLayoutChanged = { [weak self] in
            self?.resizePanel()
        }
    }

    public var isVisible: Bool {
        self.panel?.isVisible ?? false
    }

    public func toggle() {
        if self.isVisible {
            self.hide()
        } else {
            self.show()
        }
    }

    /// Same path as pressing ↩ / ⌘↩ / ⌥↩ — used by the debug hooks.
    public func commitSelection(modifier: LauncherViewModel.CommitModifier = .none) {
        self.viewModel.commit(modifier: modifier)
    }

    /// Same path as typing into the field — used by the debug hooks.
    public func setQuery(_ query: String) {
        self.viewModel.query = query
        self.viewModel.scheduleSearch()
    }

    /// Re-runs the current query in place — lets a background source (the
    /// Spotify monitor) refresh an already-open panel's rows.
    public func refreshRows() {
        self.viewModel.scheduleSearch()
    }

    /// Same path as ↑/↓ — used by the debug hooks.
    public func moveSelection(_ delta: Int) {
        self.viewModel.moveSelection(delta)
    }

    public func show(scope: LauncherScope? = nil, query: String? = nil, target: NSRunningApplication? = nil) {
        guard !self.isVisible else { return }
        self.targetApp = target ?? NSWorkspace.shared.frontmostApplication
        self.viewModel.targetAppName = self.targetApp?.localizedName ?? "previous app"
        // Reconcile the now-playing snapshot before rows render; if a track
        // change was missed, its onChange fires and refreshes the open panel.
        self.onWillShow()

        let panel = self.panel ?? self.makePanel()
        self.panel = panel

        // Resume the previous text only briefly after a dismiss; later reopens
        // (or the first-ever open) start fresh.
        let stale = self.lastHiddenAt.map { Date().timeIntervalSince($0) > Self.resumeWindow } ?? true

        self.viewModel.prepareForShow(clearQuery: stale)
        if let scope {
            self.viewModel.setScope(scope)
        }
        if let query {
            self.viewModel.query = query; self.viewModel.scheduleSearch()
        }
        self.viewModel.startObserving()
        // Apply the final scope's viewport before ordering the panel onscreen,
        // including the first summon while suggestions are still loading.
        panel.setFrame(self.frame(on: self.screenWithMouse()), display: false)
        panel.makeKeyAndOrderFront(nil)
        // Preserved text refocuses select-all by default; drop the caret at the
        // end so the next keystroke appends instead of replacing. The field
        // editor only exists once SwiftUI begins editing, so defer a tick.
        DispatchQueue.main.async { [weak panel] in
            guard let editor = panel?.fieldEditor(false, for: nil) as? NSTextView else { return }
            editor.selectedRange = NSRange(location: editor.string.count, length: 0)
            // Overboard never activates (nonactivating panel + accessory app),
            // so AppKit draws text selection "unemphasized" — a faint gray
            // that's invisible on the dark glass. Pinning the emphasized
            // attributes keeps ⌘A visibly highlighted; they persist on the
            // shared field editor across refocus (e.g. ⌘K palette roundtrip).
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor.selectedTextBackgroundColor,
                .foregroundColor: NSColor.selectedTextColor,
            ]
        }
        self.installMonitors()
    }

    public func hide() {
        // Every commit also funnels through here, so this captures Enter,
        // Escape, and click-outside alike.
        self.viewModel.closePalette()
        self.viewModel.stopObserving()
        self.viewModel.recordCurrentQuery()
        self.onWillHide()
        self.removeMonitors()
        self.panel?.orderOut(nil)
        self.targetApp = nil
        self.lastHiddenAt = Date()
    }
}
