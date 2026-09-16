import AppKit
import SwiftUI

/// Embeds SwiftUI inside a plain AppKit content view so `NSHostingView`
/// cannot resize its owning window during layout. The edge constraints make
/// fixed-size panels fill their AppKit frame while preserving intrinsic
/// fitting-size propagation for content-sized panels such as the HUD.
enum PanelHosting {
    static func container<Content: View>(
        rootView: Content,
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
