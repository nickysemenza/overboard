import AppKit
import OverboardCore
import SwiftUI

/// Owns the emoji picker panel lifecycle: summon, position, key handling,
/// dismiss. Same shape as LauncherPanelController but simpler — the panel is a
/// fixed-size scrolling grid, so there's no grow-with-rows bookkeeping, no
/// resume window, and no action palette.
public final class EmojiPanelController {
    private let viewModel: EmojiPickerViewModel
    private var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// The app that was frontmost when the picker was summoned — where the
    /// picked emoji gets pasted.
    public private(set) var targetApp: NSRunningApplication?

    public var onPaste: (String, NSRunningApplication?) -> Void = { _, _ in }
    public var onCopy: (String) -> Void = { _ in }

    private enum Metrics {
        static let panelWidth: CGFloat = 400
        static let panelHeight: CGFloat = 460
    }

    public init(viewModel: EmojiPickerViewModel) {
        self.viewModel = viewModel
        viewModel.onPick = { [weak self] emoji in
            guard let self else { return }
            // Capture before hide() — hiding clears targetApp.
            let target = self.targetApp
            self.hide()
            self.onPaste(emoji.character, target)
        }
        viewModel.onCopy = { [weak self] emoji in
            guard let self else { return }
            self.hide()
            self.onCopy(emoji.character)
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

    /// Same path as typing into the field — used by the debug hooks.
    public func setQuery(_ query: String) {
        self.viewModel.query = query
    }

    /// Same path as pressing ↩ / ⌘↩ — used by the debug hooks.
    public func commitSelection(copyOnly: Bool = false) {
        self.viewModel.commit(copyOnly: copyOnly)
    }

    /// Same path as the arrow keys — used by the debug hooks.
    public func moveSelection(_ direction: EmojiGridLayout.Direction) {
        self.viewModel.moveSelection(direction)
    }

    public func show() {
        guard !self.isVisible else { return }
        self.targetApp = NSWorkspace.shared.frontmostApplication

        let panel = self.panel ?? self.makePanel()
        self.panel = panel
        panel.setFrame(self.frame(on: self.screenWithMouse()), display: false)
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
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: Metrics.panelHeight)
        )
        panel.contentView = PanelHosting.container(
            rootView: EmojiPickerView(viewModel: self.viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top),
            frame: panel.contentLayoutRect
        )
        return panel
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - Metrics.panelWidth / 2,
            y: PanelPlacement.anchoredTop(on: visible) - Metrics.panelHeight,
            width: Metrics.panelWidth,
            height: Metrics.panelHeight
        )
    }

    private func screenWithMouse() -> NSScreen {
        PanelPlacement.screenWithMouse()
    }

    // MARK: - Event monitors

    private func installMonitors() {
        // Arrows and commits are handled here; everything else falls through to
        // the search field (which keeps focus — grid selection is monitor-driven,
        // so field caret navigation via arrows is deliberately sacrificed).
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }

            switch KeyCode(rawValue: event.keyCode) {
            case .escape: // clears the throwaway query first; second esc dismisses
                if self.viewModel.query.isEmpty {
                    self.hide()
                } else {
                    self.viewModel.query = ""
                }
                return nil
            case .leftArrow:
                self.viewModel.moveSelection(.left)
                return nil
            case .rightArrow:
                self.viewModel.moveSelection(.right)
                return nil
            case .downArrow:
                self.viewModel.moveSelection(.down)
                return nil
            case .upArrow:
                self.viewModel.moveSelection(.up)
                return nil
            case .returnKey, .keypadEnter: // ⌘ copies instead of pasting
                self.viewModel.commit(copyOnly: event.modifierFlags.contains(.command))
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

        // Per-panel object: also hides us when the drawer or launcher steals
        // key, which is the three-way panel mutual exclusion.
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
}
