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
        // The panel's frame is set from AppKit (`show()` / `resizePanel`) and
        // the content fills it. A hosting view that *is* the window's content
        // view resizes the window to SwiftUI's ideal height on every layout
        // (`NSHostingView.windowDidLayout`, regardless of `sizingOptions`) —
        // which, once the preview pane (a `maxHeight: .infinity` body) is
        // showing, is just its header and footer: the panel collapsed to
        // ~190pt with an empty pane, and while the strip was showing it fought
        // the frame animation for the same window. Hosting inside a plain
        // container view keeps that path out of the picture.
        hosting.sizingOptions = []
        let container = NSView(frame: panel.contentLayoutRect)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        return panel
    }

    /// The collapsed panel height: the drawer's own measured chrome once it
    /// has laid out (the saved-search chip bar makes it variable), else the
    /// `CardMetrics` estimate for the very first show.
    var collapsedPanelHeight: CGFloat {
        self.viewModel.collapsedShellHeight.map { $0 + DrawerView.outerPadding * 2 }
            ?? CardMetrics.collapsedPanelHeight
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
        let height = expanded ? CardMetrics.expandedPanelHeight : self.collapsedPanelHeight
        let frame = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    func screenWithMouse() -> NSScreen {
        PanelPlacement.screenWithMouse()
    }
}
