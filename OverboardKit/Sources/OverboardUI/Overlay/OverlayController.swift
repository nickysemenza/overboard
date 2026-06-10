import AppKit
import os
import OverboardCore
import SwiftUI

/// Owns the overlay panel lifecycle: summon, position, key handling, dismiss.
@MainActor
public final class OverlayController {
    private let viewModel: DrawerViewModel
    private var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "overlay")

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
    public var onRunAction: (ClipAction, [ClipItem], NSRunningApplication?) -> Void = { _, _, _ in }

    public init(store: ClipStore, stack: PasteStack) {
        self.viewModel = DrawerViewModel(store: store, stack: stack)
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
        if self.isVisible { self.hide() } else { self.show() }
    }

    public func show() {
        guard !self.isVisible else { return }
        self.targetApp = NSWorkspace.shared.frontmostApplication

        let panel = self.panel ?? self.makePanel()
        self.panel = panel

        let screen = self.screenWithMouse()
        let visible = screen.visibleFrame
        let height: CGFloat = 282
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

    // MARK: - Setup

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 282))
        let hosting = NSHostingView(
            rootView: DrawerView(viewModel: self.viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        )
        panel.contentView = hosting
        return panel
    }

    /// Grows the panel for the preview pane and shrinks it back, bottom-anchored.
    private func resizePanel(expanded: Bool) {
        guard let panel, panel.isVisible else { return }
        let screen = panel.screen ?? self.screenWithMouse()
        let visible = screen.visibleFrame
        let height: CGFloat = expanded ? 540 : 282
        panel.setFrame(
            NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height),
            display: true,
            animate: true
        )
    }

    private func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Event monitors

    private func installMonitors() {
        // Keyboard model. Everything not handled here falls through to the
        // search field, so typing always filters.
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }

            // The palette owns the keyboard above everything else.
            if self.viewModel.isPaletteOpen {
                switch event.keyCode {
                case 53: // esc closes the palette, not the drawer
                    self.viewModel.closePalette()
                    return nil
                case 36, 76: // return runs the highlighted action
                    self.viewModel.runPaletteAction()
                    return nil
                case 126: // up
                    self.viewModel.movePaletteSelection(-1)
                    return nil
                case 125: // down
                    self.viewModel.movePaletteSelection(1)
                    return nil
                default: // typing filters
                    return event
                }
            }

            // Preview/edit modes own the keyboard before the normal model.
            switch self.viewModel.previewState {
            case .editing:
                switch event.keyCode {
                case 53: // esc cancels the edit, back to the card strip
                    self.viewModel.closePreview()
                    return nil
                case 36 where event.modifierFlags.contains(.command): // ⌘↩ paste edited
                    self.viewModel.commitEdit()
                    return nil
                default: // everything else belongs to the text editor
                    return event
                }
            case .viewing:
                switch event.keyCode {
                case 53, 49: // esc, space close
                    self.viewModel.closePreview()
                    return nil
                case 16 where event.modifierFlags.contains(.command): // ⌘Y closes too
                    self.viewModel.closePreview()
                    return nil
                case 36, 76: // return pastes (⇧ plain)
                    let mode: PasteMode = event.modifierFlags.contains(.shift) ? .plainText : .full
                    self.viewModel.selectCurrent(mode: mode)
                    return nil
                case 123: // browse while previewing
                    self.viewModel.moveSelection(-1)
                    return nil
                case 124:
                    self.viewModel.moveSelection(1)
                    return nil
                case 14 where event.modifierFlags.contains(.command): // ⌘E edit
                    self.viewModel.beginEdit()
                    return nil
                default:
                    return nil // swallow stray typing while previewing
                }
            case .hidden:
                break
            }

            switch event.keyCode {
            case 53: // esc
                self.hide()
                return nil
            case 49 where self.viewModel.query.isEmpty && self.viewModel.mode == .history: // space previews
                self.viewModel.togglePreview()
                return nil
            case 16 where event.modifierFlags.contains(.command): // ⌘Y previews even mid-search
                self.viewModel.togglePreview()
                return nil
            case 14 where event.modifierFlags.contains(.command): // ⌘E edit before paste
                self.viewModel.beginEdit()
                return nil
            case 40 where event.modifierFlags.contains(.command): // ⌘K action palette
                self.viewModel.togglePalette()
                return nil
            case 36, 76: // return, keypad enter — ⇧ plain text, ⌘ queue on stack
                if event.modifierFlags.contains(.command) {
                    self.viewModel.addSelectedToStack()
                } else {
                    let mode: PasteMode = event.modifierFlags.contains(.shift) ? .plainText : .full
                    self.viewModel.selectCurrent(mode: mode)
                }
                return nil
            case 44 where event.modifierFlags.contains(.command): // ⌘/ history ⇄ snippets
                self.viewModel.toggleMode()
                return nil
            case 43 where event.modifierFlags.contains(.command): // ⌘, settings
                self.hide()
                self.viewModel.onOpenSettings()
                return nil
            case 123: // left arrow — ⇧ extends the selection
                if event.modifierFlags.contains(.shift) {
                    self.viewModel.extendSelection(-1)
                } else {
                    self.viewModel.moveSelection(-1)
                }
                return nil
            case 124: // right arrow — ⇧ extends the selection
                if event.modifierFlags.contains(.shift) {
                    self.viewModel.extendSelection(1)
                } else {
                    self.viewModel.moveSelection(1)
                }
                return nil
            case 35 where event.modifierFlags.contains(.command): // ⌘P pin/unpin
                self.viewModel.togglePinSelected()
                return nil
            case 51 where event.modifierFlags.contains(.command): // ⌘⌫ delete item
                self.viewModel.deleteSelected()
                return nil
            default:
                if event.modifierFlags.contains(.command),
                   let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
                   (1 ... 9).contains(digit)
                {
                    self.viewModel.select(at: digit - 1)
                    return nil
                }
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

        // Covers ⌘-tab, clicking another of our windows, etc.
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
