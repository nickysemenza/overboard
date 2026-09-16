import AppKit
import SwiftUI

/// Embeds SwiftUI inside a plain AppKit content view so `NSHostingView`
/// cannot resize its owning window during layout.
///
/// A hosting view that *is* the window's content view resizes the window to
/// SwiftUI's ideal height on every layout (`NSHostingView.windowDidLayout`,
/// regardless of `sizingOptions`). For the drawer — whose preview pane is a
/// `maxHeight: .infinity` body — that ideal height is just its header and
/// footer: the panel collapsed to ~190pt with an empty pane, and while the
/// strip was showing it fought the frame animation for the same window.
/// Hosting inside a plain container view keeps that path out of the picture.
///
/// The edge constraints make fixed-size panels fill their AppKit frame while
/// preserving intrinsic fitting-size propagation for content-sized panels
/// such as the HUD (`tracksContentSize`), whose controller reads the
/// container's `fittingSize` to size the window itself.
enum PanelHosting {
    static func container(
        rootView: some View,
        frame: NSRect,
        tracksContentSize: Bool = false
    ) -> NSView {
        let container = NSView(frame: frame)
        let hosting = NSHostingView(rootView: rootView)
        if !tracksContentSize {
            hosting.sizingOptions = []
        }
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}
