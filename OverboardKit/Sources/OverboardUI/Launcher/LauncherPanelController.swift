import AppKit
import OverboardCore
import SwiftUI

/// Owns the launcher panel lifecycle: summon, position, key handling,
/// dismiss. Same shape as OverlayController, but centered Spotlight-style
/// and with a vertical-list keyboard model.
public final class LauncherPanelController {
    private let viewModel: LauncherViewModel
    private let store: ClipStore
    private var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// When the launcher was last dismissed; reopening within `resumeWindow`
    /// resumes the previous text, otherwise the bar opens fresh.
    private var lastHiddenAt: Date?
    private static let resumeWindow: TimeInterval = 10

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

    private enum Metrics {
        static let panelWidth: CGFloat = 740
        /// Reserve the result viewport before showing the window. Rows and
        /// section headings scroll inside it instead of moving the search field.
        static let panelHeight: CGFloat = 612
        static let previewWidth: CGFloat = 1020
        static let previewHeight: CGFloat = 650
        static let clipboardFilterHeight: CGFloat = 36
    }

    public init(store: ClipStore, viewModel: LauncherViewModel) {
        self.store = store
        self.viewModel = viewModel
        viewModel.onCopyText = { [weak self] text in
            guard let self else { return }
            self.hide()
            self.onCopyText(text)
        }
        viewModel.onPasteText = { [weak self] text in
            guard let self else { return }
            let target = self.targetApp
            self.hide()
            self.onPasteText(text, target)
        }
        viewModel.onOpenFile = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onOpenFile(url)
        }
        viewModel.onRevealFile = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onRevealFile(url)
        }
        viewModel.onCopyPath = { [weak self] path in
            guard let self else { return }
            self.hide()
            self.onCopyPath(path)
        }
        viewModel.onOpenWebSearch = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onOpenWebSearch(url)
        }
        viewModel.onOpenSystemSetting = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onOpenSystemSetting(url)
        }
        viewModel.onPasteClip = { [weak self] item, mode in
            guard let self else { return }
            // Capture before hide() — hiding clears targetApp.
            let target = self.targetApp
            self.hide()
            self.onPasteClip(item, mode, target)
        }
        viewModel.onCopyClip = { [weak self] item in
            guard let self else { return }
            self.hide()
            self.onCopyClip(item)
        }
        viewModel.onPasteSnippet = { [weak self] snippet in
            guard let self else { return }
            let target = self.targetApp
            self.hide()
            self.onPasteSnippet(snippet, target)
        }
        viewModel.onCopySnippet = { [weak self] snippet in
            guard let self else { return }
            self.hide()
            self.onCopySnippet(snippet)
        }
        viewModel.onRunCommand = { [weak self] command in
            guard let self else { return }
            self.hide()
            self.onRunCommand(command)
        }
        viewModel.onCopyNowPlayingLink = { [weak self] track in
            guard let self else { return }
            self.hide()
            self.onCopyNowPlayingLink(track)
        }
        viewModel.onOpenSpotify = { [weak self] track in
            guard let self else { return }
            self.hide()
            self.onOpenSpotify(track)
        }
        viewModel.onAskAI = { [weak self] prompt, delivery in
            guard let self else { return }
            // Capture before hide() — hiding clears targetApp — so a pasted
            // result lands in the app that was frontmost when we were summoned.
            let target = self.targetApp
            self.hide()
            self.onAskAI(prompt, delivery, target)
        }
        viewModel.onQuitApp = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onQuitApp(url)
        }
        viewModel.onOpenClipLink = { [weak self] url in
            guard let self else { return }
            self.hide()
            self.onOpenClipLink(url)
        }
        viewModel.onLayoutChanged = { [weak self] in
            self?.resizePanel()
        }
    }

    public var isVisible: Bool {
        self.panel?.isVisible ?? false
    }

    public func toggle() {
        if self.isVisible { self.hide() } else { self.show() }
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
        if let scope { self.viewModel.setScope(scope) }
        if let query { self.viewModel.query = query; self.viewModel.scheduleSearch() }
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

    // MARK: - Setup

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: Metrics.panelHeight)
        )
        let hosting = NSHostingView(
            rootView: LauncherView(viewModel: self.viewModel, store: self.store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        panel.contentView = hosting
        return panel
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(self.viewModel.showsPreview ? Metrics.previewWidth : Metrics.panelWidth, visible.width - 40)
        var height = self.viewModel.showsPreview ? Metrics.previewHeight : Metrics.panelHeight
        if self.viewModel.scope == .clipboard { height += Metrics.clipboardFilterHeight }
        height = min(height, visible.height - 60)
        let compactHeight = min(Metrics.panelHeight, visible.height - 60)
        let top = min(visible.maxY - 30, visible.midY + compactHeight / 2 + 60)
        return NSRect(x: visible.midX - width / 2, y: max(visible.minY + 30, top - height), width: width, height: height)
    }

    /// Only an explicit scope/preview change can resize the panel. Keep its
    /// top edge anchored and avoid resetting an unchanged AppKit frame.
    private func resizePanel() {
        guard let panel, panel.isVisible else { return }
        let screen = panel.screen ?? self.screenWithMouse()
        let frame = self.frame(on: screen)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// The ⌘K palette fits inside the reserved result viewport.
    private func setPaletteOpen(_ open: Bool) {
        guard open != self.viewModel.isPaletteOpen else { return }
        self.viewModel.togglePalette()
    }

    private func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Event monitors

    private func installMonitors() {
        // Everything not handled here falls through to the text field.
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }

            // The ⌘K palette owns the keyboard while open (mirrors the drawer):
            // esc closes only the palette, ↑/↓ move its selection, ↩ runs it.
            if self.viewModel.isPaletteOpen {
                switch KeyCode(rawValue: event.keyCode) {
                case .escape: // closes the palette, not the launcher
                    self.setPaletteOpen(false)
                    return nil
                case .returnKey, .keypadEnter: // runs the highlighted action
                    self.viewModel.runPaletteAction()
                    return nil
                case .upArrow:
                    self.viewModel.movePaletteSelection(-1)
                    return nil
                case .downArrow:
                    self.viewModel.movePaletteSelection(1)
                    return nil
                default: // typing filters
                    return event
                }
            }

            let scopeKeys: [KeyCode] = [.one, .two, .three, .four]
            if event.modifierFlags.contains(.command),
               let index = scopeKeys.firstIndex(where: { $0.rawValue == event.keyCode })
            {
                self.viewModel.setScope(LauncherScope.allCases[index])
                return nil
            }
            switch KeyCode(rawValue: event.keyCode) {
            case .y where event.modifierFlags.contains(.command): // ⌘Y previews without consuming query spaces
                self.viewModel.togglePreview()
                return nil
            case .escape:
                if self.viewModel.isPreviewVisible { self.viewModel.togglePreview(); return nil }
                self.hide()
                return nil
            case .upArrow:
                self.viewModel.moveSelection(-1)
                return nil
            case .downArrow:
                self.viewModel.moveSelection(1)
                return nil
            case .k where event.modifierFlags.contains(.command): // ⌘K action palette
                self.setPaletteOpen(!self.viewModel.isPaletteOpen)
                return nil
            case .delete where event.modifierFlags.contains(.command): // ⌘⌫
                // Delete the highlighted recent search; fall through to normal
                // text editing when the selected row isn't a recent.
                return self.viewModel.deleteSelectedRecent() ? nil : event
            case .returnKey, .keypadEnter:
                let modifier: LauncherViewModel.CommitModifier = if event.modifierFlags.contains(.command) {
                    .command
                } else if event.modifierFlags.contains(.option) {
                    .option
                } else {
                    .none
                }
                self.viewModel.commit(modifier: modifier)
                return nil
            default:
                return event
            }
        }

        // Click anywhere outside the panel dismisses.
        self.clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }

        // Per-panel object: also hides us when the drawer steals key, which
        // is the drawer↔launcher mutual exclusion.
        self.resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: self.panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        self.keyMonitor = nil
        self.clickMonitor = nil
        self.resignObserver = nil
    }
}
