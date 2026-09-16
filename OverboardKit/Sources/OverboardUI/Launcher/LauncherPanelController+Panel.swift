import AppKit
import SwiftUI

/// NSPanel construction and sizing/positioning for the launcher window.
extension LauncherPanelController {
    enum Metrics {
        static let panelWidth: CGFloat = 740
        /// Reserve the result viewport before showing the window. Rows and
        /// section headings scroll inside it instead of moving the search field.
        static let panelHeight: CGFloat = 612
        static let previewWidth: CGFloat = 1020
        static let previewHeight: CGFloat = 650
        static let clipboardFilterHeight: CGFloat = 36
    }

    func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: Metrics.panelHeight)
        )
        panel.contentView = PanelHosting.container(
            rootView: LauncherView(viewModel: self.viewModel, store: self.store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top),
            frame: panel.contentLayoutRect
        )
        return panel
    }

    func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(self.viewModel.showsPreview ? Metrics.previewWidth : Metrics.panelWidth, visible.width - 40)
        var height = self.viewModel.showsPreview ? Metrics.previewHeight : Metrics.panelHeight
        if self.viewModel.scope == .clipboard {
            height += Metrics.clipboardFilterHeight
        }
        height = min(height, visible.height - 60)
        let top = PanelPlacement.anchoredTop(on: visible)
        return NSRect(
            x: visible.midX - width / 2,
            y: max(visible.minY + 30, top - height),
            width: width,
            height: height
        )
    }

    /// Only an explicit scope/preview change can resize the panel. Keep its
    /// top edge anchored and avoid resetting an unchanged AppKit frame.
    /// Animates like the drawer's own resize, gated the same way on Reduce
    /// Motion.
    func resizePanel() {
        guard let panel, panel.isVisible else { return }
        let screen = panel.screen ?? self.screenWithMouse()
        let frame = self.frame(on: screen)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func screenWithMouse() -> NSScreen {
        PanelPlacement.screenWithMouse()
    }
}
