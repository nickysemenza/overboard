import AppKit

/// The load-bearing trick of the whole app: a borderless panel that can become
/// *key* (so the search field receives typing) without *activating* Overboard —
/// the target app stays frontmost and keyboard focus snaps back to it the
/// instant we dismiss.
public final class OverlayPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
        // .utilityWindow animation left the panel stuck on screen after
        // orderOut (window server kept it at alpha 1 while isVisible read
        // false). We animate content in SwiftUI instead.
        self.animationBehavior = .none
        self.becomesKeyOnlyIfNeeded = false
        self.isReleasedWhenClosed = false
    }

    /// Borderless windows refuse key status by default; without this override
    /// the search field can never focus.
    override public var canBecomeKey: Bool {
        true
    }

    override public var canBecomeMain: Bool {
        false
    }
}
