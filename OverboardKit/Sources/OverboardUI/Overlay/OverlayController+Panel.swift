import AppKit
import SwiftUI

// MARK: - Panel / window configuration

extension OverlayController {
    func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: CardMetrics.collapsedPanelHeight))
        let hosting = NSHostingView(
            rootView: DrawerView(viewModel: self.viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        )
        panel.contentView = hosting
        return panel
    }

    /// Grows the panel for the preview pane and shrinks it back, bottom-anchored.
    func resizePanel(expanded: Bool) {
        guard let panel, panel.isVisible else { return }
        let screen = panel.screen ?? self.screenWithMouse()
        let visible = screen.visibleFrame
        let height = expanded ? CardMetrics.expandedPanelHeight : CardMetrics.collapsedPanelHeight
        panel.setFrame(
            NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height),
            display: true,
            animate: true
        )
    }

    func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
