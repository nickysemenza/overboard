import AppKit
import OverboardCore
import SwiftUI

/// Owns the overlay panel lifecycle: summon, position, key handling, dismiss.
public final class OverlayController {
    /// `internal`: read from OverlayController+Panel.swift and
    /// OverlayController+Keyboard.swift.
    let viewModel: DrawerViewModel
    /// `internal`: read/set from OverlayController+Panel.swift and
    /// OverlayController+Keyboard.swift.
    var panel: OverlayPanel?
    var keyMonitor: Any?
    var clickMonitor: Any?
    var resignObserver: NSObjectProtocol?

    /// The app that was frontmost when the drawer was summoned — i.e. where a
    /// paste should land. Recorded before the panel appears.
    public private(set) var targetApp: NSRunningApplication?

    /// Called with the committed item, paste mode, and the recorded target app.
    public var onCommit: (ClipItem, PasteMode, NSRunningApplication?) -> Void = { _, _, _ in }
    /// Called with the committed snippet and the recorded target app.
    public var onCommitSnippet: (Snippet, NSRunningApplication?) -> Void = { _, _ in }
    /// Called when the user pastes an item through a transform.
    public var onCommitTransform: (ClipItem, ClipTransform, NSRunningApplication?) -> Void = { _, _, _ in }
    /// Called when the user pastes an item through an LLM transform.
    public var onCommitAITransform: (ClipItem, AITransform, NSRunningApplication?) -> Void = { _, _, _ in }
    /// Called when the user pastes edited text from the preview pane.
    public var onCommitEditedText: (String, NSRunningApplication?) -> Void = { _, _ in }
    /// Called when the user runs a clip action on the selection.
    public var onBrowseHistory: (String, NSRunningApplication?) -> Void = { _, _ in }
    public var onRunAction: (ClipAction, [ClipItem], NSRunningApplication?) -> Void = { _, _, _ in }

    public init(store: ClipStore, stack: PasteStack) {
        self.viewModel = DrawerViewModel(store: store, stack: stack)
        self.installCommitCallbacks()
        self.installActionCallbacks()
    }

    /// Wires every "the user committed something" path — a paste (plain,
    /// transformed, AI, or hand-edited text) or a snippet paste. Each hides
    /// the panel first, then hands off with the recorded target app.
    private func installCommitCallbacks() {
        self.viewModel.onCommit = { [weak self] item, mode in
            guard let self else { return }
            let target = self.targetApp
            self.hide()
            self.onCommit(item, mode, target)
        }
        self.viewModel.onCommitSnippet = { [weak self] snippet in
            guard let self else { return }
            let target = self.targetApp
            self.hide()
            self.onCommitSnippet(snippet, target)
        }
        self.viewModel.onCommitTransform = { [weak self] item, transform in
            guard let self else { return }
            let target = self.targetApp
            self.hide()
            self.onCommitTransform(item, transform, target)
        }
        self.viewModel.onCommitAITransform = { [weak self] item, transform in
            guard let self else { return }
            let target = self.targetApp
            self.hide()
            self.onCommitAITransform(item, transform, target)
        }
        self.viewModel.onCommitEditedText = { [weak self] text in
            guard let self else { return }
            let target = self.targetApp
            self.hide()
            self.onCommitEditedText(text, target)
        }
    }

    /// Wires the remaining view-model callbacks: panel resizing, running a
    /// clip action, dismissal, and handing a query off to the launcher's
    /// browse-history view.
    private func installActionCallbacks() {
        self.viewModel.onPreviewVisibilityChanged = { [weak self] expanded in
            self?.resizePanel(expanded: expanded)
        }
        self.viewModel.onRunAction = { [weak self] action, items in
            guard let self else { return }
            let target = self.targetApp
            // Paste-producing actions need the drawer out of the way; HUD-only
            // ones could keep it open, but consistency wins.
            self.hide()
            self.onRunAction(action, items, target)
        }
        self.viewModel.onDismiss = { [weak self] in self?.hide() }
        self.viewModel.onBrowseHistory = { [weak self] in
            guard let self else { return }
            let query = self.viewModel.query
            let target = self.targetApp
            self.hide()
            self.onBrowseHistory(query, target)
        }
    }

    public var isVisible: Bool {
        self.panel?.isVisible ?? false
    }

    /// Commits the currently selected item — same path as pressing Return.
    public func commitSelection(mode: PasteMode = .full) {
        self.viewModel.selectCurrent(mode: mode)
    }

    /// Pin/unpin the selected item — same path as ⌘P.
    public func togglePinSelection() {
        self.viewModel.togglePinSelected()
    }

    /// Delete the selected item — same path as ⌘⌫.
    public func deleteSelection() {
        self.viewModel.deleteSelected()
    }

    /// Toggle the preview pane — same path as space/⌘Y.
    public func togglePreviewSelection() {
        self.viewModel.togglePreview()
    }

    /// Move the selection — same path as ←/→.
    public func moveSelection(_ delta: Int) {
        self.viewModel.moveSelection(delta)
    }

    /// Grow the multi-selection — same path as ⇧→/⇧←.
    public func extendSelection(_ delta: Int) {
        self.viewModel.extendSelection(delta)
    }

    /// Toggle the action palette — same path as ⌘K.
    public func togglePalette() {
        self.viewModel.togglePalette()
    }

    /// Queue the selected item on the paste stack — same path as ⌘↩.
    public func addSelectedToStack() {
        self.viewModel.addSelectedToStack()
    }

    public func toggle() {
        if self.isVisible {
            self.hide()
        } else {
            self.show()
        }
    }

    public func show() {
        guard !self.isVisible else { return }
        self.targetApp = NSWorkspace.shared.frontmostApplication
        self.viewModel.targetAppName = self.targetApp?.localizedName
            ?? String(localized: "previous app", bundle: .module)

        let panel = self.panel ?? self.makePanel()
        self.panel = panel

        let screen = self.screenWithMouse()
        let visible = screen.visibleFrame
        let height = self.collapsedPanelHeight
        panel.setFrame(
            NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height),
            display: false
        )

        self.viewModel.prepareForShow()
        self.viewModel.startLiveUpdates()
        panel.makeKeyAndOrderFront(nil)
        self.installMonitors()
    }

    public func hide() {
        self.viewModel.stopLiveUpdates()
        self.removeMonitors()
        self.panel?.orderOut(nil)
        self.targetApp = nil
    }
}
