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
    ///
    /// The panel itself is transparent (`OverlayPanel`: clear background, no
    /// shadow) and always bottom-anchored, so an instant resize is invisible
    /// — there's no chrome to see snap. The visible motion is entirely
    /// SwiftUI's: `DrawerViewModel+Preview.swift` animates `previewState`
    /// with a spring, ordered so the panel is already the right size before
    /// (or still the right size until after) the content transitions. Two
    /// concurrent, unsynchronized animation systems — this AppKit frame
    /// animation and SwiftUI's own — used to fight over the same layout and
    /// look jittery.
    func resizePanel(expanded: Bool) {
        guard let panel, panel.isVisible else { return }
        let screen = panel.screen ?? self.screenWithMouse()
        let visible = screen.visibleFrame
        let height = expanded ? CardMetrics.expandedPanelHeight : CardMetrics.collapsedPanelHeight
        let frame = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    func screenWithMouse() -> NSScreen {
        PanelPlacement.screenWithMouse()
    }
}
