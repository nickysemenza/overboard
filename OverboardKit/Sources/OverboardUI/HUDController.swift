import AppKit
import SwiftUI

/// Tiny transient toast ("Copied — press ⌘V") shown near the bottom of the
/// active screen. Never takes focus, ignores the mouse, fades on its own.
@MainActor
public final class HUDController {
    public static let shared = HUDController()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    public func flash(_ message: String, duration: Duration = .seconds(1.6)) {
        self.hideTask?.cancel()
        self.panel?.orderOut(nil)

        let content = NSHostingView(
            rootView: Text(message)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
        )
        let size = content.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        panel.contentView = content

        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 310
            ))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        self.hideTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}
