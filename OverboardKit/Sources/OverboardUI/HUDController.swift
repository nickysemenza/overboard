import AppKit
import Observation
import SwiftUI

/// Tiny transient toast ("Copied — press ⌘V") shown near the bottom of the
/// active screen. Never takes focus, ignores the mouse, fades on its own, and
/// announces itself to VoiceOver since the fade would otherwise be silent.
public final class HUDController {
    public static let shared = HUDController()

    /// Clearance from the screen's visible bottom edge. Tuned to sit above the
    /// Dock (which reserves the bottom of `visibleFrame`) with a comfortable
    /// gap, without floating up into the middle of the screen.
    private static let bottomOffset: CGFloat = 310

    /// How long the exit animation needs before it's safe to actually pull the
    /// panel off screen; reduce-motion hard-cuts, so this is skipped then.
    private static let exitAnimationDuration: Duration = .milliseconds(150)

    private let state = HUDState()
    private lazy var panel: NSPanel = self.makePanel()
    private var hideTask: Task<Void, Never>?

    private init() {}

    public func flash(_ message: String, duration: Duration = .seconds(1.6)) {
        self.hideTask?.cancel()
        self.state.message = message

        self.position(self.panel)
        self.panel.orderFrontRegardless()
        self.state.visible = true

        // The panel never takes focus, so nothing else tells VoiceOver a toast
        // just appeared — without this, the fade is silent to screen readers.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )

        self.hideTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.state.visible = false
            try? await Task.sleep(for: Self.exitAnimationDuration)
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Sizes and centers the (reused) panel above the Dock on whichever screen
    /// currently has the mouse, recomputed on every flash since the message —
    /// and therefore the panel's fitting size — changes each time.
    private func position(_ panel: NSPanel) {
        // The hosting view is reused, so its fitting size still reflects the
        // previous message until SwiftUI lays out the new one; force that pass
        // now or the capsule is sized for whatever text was shown last time.
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let size = panel.contentView?.fittingSize else { return }
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.minY + Self.bottomOffset,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    /// One panel + hosting view reused across every flash instead of
    /// allocating fresh AppKit chrome each time.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: HUDView(state: self.state))
        return panel
    }
}

@Observable
private final class HUDState {
    var message = ""
    var visible = false
}

/// The toast's content: a capsule of shared glass chrome that fades and
/// scales in/out around `state.visible`, hard-cutting under Reduce Motion the
/// same way the rest of the shared glass surfaces do.
private struct HUDView: View {
    @Bindable var state: HUDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(self.state.message)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassPanel(shape: Capsule())
            .opacity(self.state.visible ? 1 : 0)
            .scaleEffect(self.state.visible ? 1 : 0.92)
            .animation(
                self.reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75),
                value: self.state.visible
            )
    }
}
