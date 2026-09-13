import AppKit
import OverboardCore

// MARK: - Event monitors

extension OverlayController {
    func installMonitors() {
        // Keyboard model. Everything not handled here falls through to the
        // search field, so typing always filters.
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }

            // The palette owns the keyboard above everything else.
            if self.viewModel.isPaletteOpen {
                return self.handlePaletteKeyDown(event)
            }

            // Preview/edit modes own the keyboard before the normal model.
            switch self.viewModel.previewState {
            case .editing:
                return self.handleEditingKeyDown(event)
            case .viewing:
                return self.handleViewingKeyDown(event)
            case .hidden:
                break
            }

            return self.handleMainKeyDown(event)
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

    /// The ⌘K palette's keys, while it's open. Every branch returns, so the
    /// palette fully owns the event — nothing falls through.
    private func handlePaletteKeyDown(_ event: NSEvent) -> NSEvent? {
        switch KeyCode(rawValue: event.keyCode) {
        case .escape: // closes the palette, not the drawer
            self.viewModel.closePalette()
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

    /// Preview pane keys while editing the item's text.
    private func handleEditingKeyDown(_ event: NSEvent) -> NSEvent? {
        switch KeyCode(rawValue: event.keyCode) {
        case .escape: // cancels the edit, back to the card strip
            self.viewModel.closePreview()
            return nil
        case .returnKey where event.modifierFlags.contains(.command): // ⌘↩ paste edited
            self.viewModel.commitEdit()
            return nil
        default: // everything else belongs to the text editor
            return event
        }
    }

    /// Preview pane keys while viewing (not editing) the item.
    private func handleViewingKeyDown(_ event: NSEvent) -> NSEvent? {
        switch KeyCode(rawValue: event.keyCode) {
        case .escape, .space: // close
            self.viewModel.closePreview()
            return nil
        case .letterY where event.modifierFlags.contains(.command): // ⌘Y closes too
            self.viewModel.closePreview()
            return nil
        case .returnKey, .keypadEnter: // pastes (⇧ plain)
            let mode: PasteMode = event.modifierFlags.contains(.shift) ? .plainText : .full
            self.viewModel.selectCurrent(mode: mode)
            return nil
        case .leftArrow: // browse while previewing
            self.viewModel.moveSelection(-1)
            return nil
        case .rightArrow:
            self.viewModel.moveSelection(1)
            return nil
        case .letterE where event.modifierFlags.contains(.command): // ⌘E edit
            self.viewModel.beginEdit()
            return nil
        default:
            return nil // swallow stray typing while previewing
        }
    }

    /// The card-strip keys — the normal (not palette, not preview) model.
    /// Delegates to one handler per key group, each independent since no
    /// `KeyCode` appears in more than one group; the ⌘-digit jump is the only
    /// case left inline since it isn't keyed off `KeyCode` at all.
    private func handleMainKeyDown(_ event: NSEvent) -> NSEvent? {
        if self.handleDismissalKeys(event) {
            return nil
        }
        if self.handleToggleKeys(event) {
            return nil
        }
        if self.handleCommitKeys(event) {
            return nil
        }
        if self.handleNavigationKeys(event) {
            return nil
        }
        if self.handleItemActionKeys(event) {
            return nil
        }
        if event.modifierFlags.contains(.command),
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           (1 ... 9).contains(digit)
        {
            self.viewModel.select(at: digit - 1)
            return nil
        }
        return event
    }

    /// Esc (two-stage clear-then-dismiss) and ⌘, (settings).
    private func handleDismissalKeys(_ event: NSEvent) -> Bool {
        switch KeyCode(rawValue: event.keyCode) {
        case .escape:
            // Two-stage Esc (matches EmojiPanelController/LauncherPanelController):
            // a non-empty query is cleared first; the drawer only dismisses
            // once Esc is pressed again with an already-empty query.
            if !self.viewModel.query.isEmpty {
                self.viewModel.query = ""
                self.viewModel.scheduleSearch()
                return true
            }
            self.hide()
            return true
        case .comma where event.modifierFlags.contains(.command):
            self.hide()
            self.viewModel.onOpenSettings()
            return true
        default:
            return false
        }
    }

    /// Preview/edit/palette toggles: space, ⌘Y, ⌘E, ⌘K.
    private func handleToggleKeys(_ event: NSEvent) -> Bool {
        switch KeyCode(rawValue: event.keyCode) {
        case .space where self.viewModel.query.isEmpty && self.viewModel.mode == .history: // previews
            self.viewModel.togglePreview()
            return true
        case .letterY where event.modifierFlags.contains(.command): // ⌘Y previews even mid-search
            self.viewModel.togglePreview()
            return true
        case .letterE where event.modifierFlags.contains(.command): // ⌘E edit before paste
            self.viewModel.beginEdit()
            return true
        case .letterK where event.modifierFlags.contains(.command): // ⌘K action palette
            self.viewModel.togglePalette()
            return true
        default:
            return false
        }
    }

    /// Return/Enter (paste, or ⌘ to queue on the stack) and ⌘/ (mode toggle).
    private func handleCommitKeys(_ event: NSEvent) -> Bool {
        switch KeyCode(rawValue: event.keyCode) {
        case .returnKey, .keypadEnter: // ⇧ plain text, ⌘ queue on stack
            if event.modifierFlags.contains(.command) {
                self.viewModel.addSelectedToStack()
            } else {
                let mode: PasteMode = event.modifierFlags.contains(.shift) ? .plainText : .full
                self.viewModel.selectCurrent(mode: mode)
            }
            return true
        case .slash where event.modifierFlags.contains(.command): // ⌘/ history ⇄ snippets
            self.viewModel.toggleMode()
            return true
        default:
            return false
        }
    }

    /// Arrow-key navigation; ⇧ extends the selection instead of moving it.
    private func handleNavigationKeys(_ event: NSEvent) -> Bool {
        switch KeyCode(rawValue: event.keyCode) {
        case .leftArrow: // ⇧ extends the selection
            if event.modifierFlags.contains(.shift) {
                self.viewModel.extendSelection(-1)
            } else {
                self.viewModel.moveSelection(-1)
            }
            return true
        case .rightArrow: // ⇧ extends the selection
            if event.modifierFlags.contains(.shift) {
                self.viewModel.extendSelection(1)
            } else {
                self.viewModel.moveSelection(1)
            }
            return true
        default:
            return false
        }
    }

    /// Per-item actions: ⌘P pin/unpin, ⌘⌫ delete.
    private func handleItemActionKeys(_ event: NSEvent) -> Bool {
        switch KeyCode(rawValue: event.keyCode) {
        case .letterP where event.modifierFlags.contains(.command): // ⌘P pin/unpin
            self.viewModel.togglePinSelected()
            return true
        case .delete where event.modifierFlags.contains(.command): // ⌘⌫ delete item
            self.viewModel.deleteSelected()
            return true
        default:
            return false
        }
    }
}
