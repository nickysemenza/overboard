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

/// Shared geometry for the summonable panels that float over the mouse's
/// screen instead of anchoring to the drawer's bottom edge.
enum PanelPlacement {
    /// The launcher's anchored top edge: centered-high, clamped to the visible
    /// frame. Every centered summonable surface hangs from this line.
    static func anchoredTop(on visible: NSRect) -> CGFloat {
        let compactHeight = min(LauncherPanelController.Metrics.panelHeight, visible.height - 60)
        return min(visible.maxY - 30, visible.midY + compactHeight / 2 + 60)
    }

    /// The screen holding the mouse pointer, falling back to the main screen
    /// and then the first available one.
    static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
