import AppKit
import OverboardCore
import SwiftUI

/// Owns the launcher panel lifecycle: summon, position, key handling,
/// dismiss. Same shape as OverlayController, but centered Spotlight-style
/// and with a vertical-list keyboard model.
@MainActor
public final class LauncherPanelController {
    private let viewModel: LauncherViewModel
    private let store: ClipStore
    private var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// The app that was frontmost when the launcher was summoned — i.e.
    /// where a pasted calculator result should land.
    public private(set) var targetApp: NSRunningApplication?

    public var onCopyText: (String) -> Void = { _ in }
    public var onPasteText: (String, NSRunningApplication?) -> Void = { _, _ in }
    public var onOpenFile: (URL) -> Void = { _ in }
    public var onRevealFile: (URL) -> Void = { _ in }
    public var onCopyPath: (String) -> Void = { _ in }
    public var onOpenWebSearch: (URL) -> Void = { _ in }
    public var onPasteClip: (ClipItem, PasteMode, NSRunningApplication?) -> Void = { _, _, _ in }
    public var onCopyClip: (ClipItem) -> Void = { _ in }
    public var onPasteSnippet: (Snippet, NSRunningApplication?) -> Void = { _, _ in }
    public var onCopySnippet: (Snippet) -> Void = { _ in }

    private enum Metrics {
        static let panelWidth: CGFloat = 640
        /// Outer padding (12×2) + glass padding (14×2) + search bar (30).
        static let barOnlyHeight: CGFloat = 82
        /// Divider plus its VStack gaps.
        static let dividerHeight: CGFloat = 17
        static let rowHeight: CGFloat = 45
        /// Fraction of the screen's visible height where the bar's top sits.
        static let topFraction: CGFloat = 0.72
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
        viewModel.onResultCountChanged = { [weak self] count in
            self?.resizePanel(rows: count)
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

    /// Same path as ↑/↓ — used by the debug hooks.
    public func moveSelection(_ delta: Int) {
        self.viewModel.moveSelection(delta)
    }

    public func show() {
        guard !self.isVisible else { return }
        self.targetApp = NSWorkspace.shared.frontmostApplication

        let panel = self.panel ?? self.makePanel()
        self.panel = panel

        panel.setFrame(self.frame(forRows: 0, on: self.screenWithMouse()), display: false)
        self.viewModel.prepareForShow()
        panel.makeKeyAndOrderFront(nil)
        self.installMonitors()
    }

    public func hide() {
        self.removeMonitors()
        self.panel?.orderOut(nil)
        self.targetApp = nil
    }

    // MARK: - Setup

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: Metrics.barOnlyHeight)
        )
        let hosting = NSHostingView(
            rootView: LauncherView(viewModel: self.viewModel, store: self.store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        panel.contentView = hosting
        return panel
    }

    private func frame(forRows rows: Int, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        var height = Metrics.barOnlyHeight
        if rows > 0 {
            height += Metrics.dividerHeight + CGFloat(rows) * Metrics.rowHeight
        }
        let top = visible.minY + visible.height * Metrics.topFraction
        return NSRect(
            x: visible.midX - Metrics.panelWidth / 2,
            y: top - height,
            width: Metrics.panelWidth,
            height: height
        )
    }

    /// Grows downward as rows arrive; the bar's top edge stays put.
    private func resizePanel(rows: Int) {
        guard let panel, panel.isVisible else { return }
        let screen = panel.screen ?? self.screenWithMouse()
        panel.setFrame(self.frame(forRows: rows, on: screen), display: true)
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
            switch event.keyCode {
            case 53: // esc
                self.hide()
                return nil
            case 126: // up
                self.viewModel.moveSelection(-1)
                return nil
            case 125: // down
                self.viewModel.moveSelection(1)
                return nil
            case 36, 76: // return, keypad enter
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
