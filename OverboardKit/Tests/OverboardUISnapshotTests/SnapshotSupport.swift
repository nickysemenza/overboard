import AppKit
import SnapshotTesting
import SwiftUI
import Testing

extension Trait where Self == ConditionTrait {
    /// Snapshots are recorded on a local Retina Mac; the CI VM renders at a
    /// different backing scale (no scaler driver), so images can never match.
    /// Asserted locally only. Uses `.disabled` (not `.enabled(if:)`) so the CI
    /// run reports each suite as *skipped with a reason* rather than silently
    /// executing zero tests — a green with no snapshot coverage should be
    /// visibly labelled, not mistaken for a pass. The RenderSmokeTests suite
    /// still exercises these view bodies headlessly on CI.
    static var localOnly: ConditionTrait {
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "Snapshot image comparisons are local-only: the CI VM's backing scale differs from the recorded Retina images, so they can never match. Run `swift test` locally to assert them; RenderSmokeTests covers the render paths on CI."
        )
    }
}

/// NSHostingView wrapper: ImageRenderer can't render NSViewRepresentable
/// content, and appearance must be set per-host (no NSApp under swift test).
@MainActor
func snapshotHost(
    _ view: some View,
    width: CGFloat,
    height: CGFloat,
    dark: Bool = false
) -> NSView {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    return host
}

/// Sub-pixel antialiasing drifts across macOS point releases; perceptual
/// precision absorbs it without masking real layout changes.
@MainActor var snapshotImageStrategy: Snapshotting<NSView, NSImage> {
    .image(precision: 0.99, perceptualPrecision: 0.98)
}
