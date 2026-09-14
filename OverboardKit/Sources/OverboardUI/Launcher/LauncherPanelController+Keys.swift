import AppKit
import OverboardCore

/// Keyboard and mouse/window event handling for the launcher panel. Dispatch
/// is split into small `handle*` functions purely to keep each one's
/// cyclomatic complexity down — the matched keys and their behavior are
/// unchanged from what used to be one large switch in `installMonitors`.
extension LauncherPanelController {
    func installMonitors() {
        // Everything not handled here falls through to the text field.
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handleKeyDown(event)
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

    func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        self.keyMonitor = nil
        self.clickMonitor = nil
        self.resignObserver = nil
    }

    /// The ⌘K palette owns the keyboard while open (mirrors the drawer): esc
    /// closes only the palette, ↑/↓ move its selection, ↩ runs it. Otherwise
    /// ⌘1-4 switch scope and the rest of the key map applies
    /// (`handleMainKeyDown`). Returns `nil` to consume the event, or the
    /// event itself to fall through to the text field.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if self.viewModel.isPaletteOpen {
            return self.handlePaletteKeyDown(event)
        }
        let scopeKeys: [KeyCode] = [.one, .two, .three, .four]
        if event.modifierFlags.contains(.command),
           let index = scopeKeys.firstIndex(where: { $0.rawValue == event.keyCode })
        {
            self.viewModel.setScope(LauncherScope.allCases[index])
            return nil
        }
        return self.handleMainKeyDown(event)
    }

    private func handlePaletteKeyDown(_ event: NSEvent) -> NSEvent? {
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
        case .tab: // never hands focus away from the palette
            return nil
        default: // typing filters
            return event
        }
    }

    private func handleMainKeyDown(_ event: NSEvent) -> NSEvent? {
        if self.handleCommandShortcut(event) {
            return nil
        }
        switch KeyCode(rawValue: event.keyCode) {
        case .escape:
            return self.handleEscape()
        case .upArrow:
            self.viewModel.moveSelection(-1)
            return nil
        case .downArrow:
            self.viewModel.moveSelection(1)
            return nil
        case .delete where event.modifierFlags.contains(.command): // ⌘⌫
            // Delete the highlighted recent search; fall through to normal
            // text editing when the selected row isn't a recent.
            return self.viewModel.deleteSelectedRecent() ? nil : event
        case .returnKey, .keypadEnter:
            self.viewModel.commit(modifier: self.commitModifier(for: event))
            return nil
        case .tab: // cycles the scope bar instead of moving focus
            self.viewModel.cycleScope(event.modifierFlags.contains(.shift) ? -1 : 1)
            return nil
        default:
            return event
        }
    }

    /// ⌘Y (preview) and ⌘K (action palette) — checked before the plain-key
    /// switch in `handleMainKeyDown`. Returns whether the shortcut fired
    /// (and so already consumed the event).
    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch KeyCode(rawValue: event.keyCode) {
        case .letterY: // ⌘Y previews without consuming query spaces
            self.viewModel.togglePreview()
            return true
        case .letterK: // ⌘K action palette
            self.setPaletteOpen(!self.viewModel.isPaletteOpen)
            return true
        default:
            return false
        }
    }

    /// Two-stage Esc (matches EmojiPanelController): a non-empty query is
    /// cleared first; only a second Esc, pressed once the bar is already
    /// empty, dismisses the panel. Record the query before blanking it:
    /// `hide()` also records, but by then it sees "" — without this, an
    /// abandoned search never reaches the recents list, and Esc is how most
    /// searches end.
    private func handleEscape() -> NSEvent? {
        if self.viewModel.isPreviewVisible {
            self.viewModel.togglePreview()
            return nil
        }
        if !self.viewModel.query.isEmpty {
            self.viewModel.recordCurrentQuery()
            self.viewModel.query = ""
            self.viewModel.scheduleSearch()
            return nil
        }
        self.hide()
        return nil
    }

    private func commitModifier(for event: NSEvent) -> LauncherViewModel.CommitModifier {
        if event.modifierFlags.contains(.command) {
            .command
        } else if event.modifierFlags.contains(.option) {
            .option
        } else {
            .none
        }
    }

    /// The ⌘K palette fits inside the reserved result viewport.
    private func setPaletteOpen(_ open: Bool) {
        guard open != self.viewModel.isPaletteOpen else { return }
        self.viewModel.togglePalette()
    }
}
