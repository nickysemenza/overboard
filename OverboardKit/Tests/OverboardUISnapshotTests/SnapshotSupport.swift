import AppKit
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

/// Lays a SwiftUI view out in an `NSHostingView` at a fixed size. Appearance is
/// set per-host: there's no `NSApp` under `swift test` to inherit one from.
///
/// `.glassPanel` is flattened to its `windowBackgroundColor` fallback (the
/// Reduce Transparency branch). Liquid Glass is composited by the GPU and
/// draws nothing like itself through `cacheDisplay` on a CI VM without a
/// display driver — every pixel of a glass-backed panel differed there, so the
/// launcher and emoji-picker suites could only ever pass on a real Mac. The
/// flat chrome is a real product state, and what these suites assert is
/// layout, not the glass.
@MainActor
func snapshotHost(
    _ view: some View,
    width: CGFloat,
    height: CGFloat,
    dark: Bool = false
) -> NSView {
    let host = NSHostingView(rootView: view
        .environment(\.flattensGlassPanels, true)
        .environment(\.referenceDate, Fixtures.referenceDate))
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    // One run-loop turn before the second layout: a scroll view hosting a
    // lazy stack finishes settling its content geometry asynchronously, and
    // capturing straight after the first pass occasionally caught the emoji
    // picker's grid a few points lower on CI than on the machine that
    // recorded it. Draining the loop makes the capture land after that
    // settle on every machine.
    RunLoop.main.run(until: Date())
    host.layoutSubtreeIfNeeded()
    return host
}

/// Scale every snapshot is recorded and asserted at, on every machine.
private let snapshotScale: CGFloat = 2

/// Captures a laid-out view at a pinned 2× scale, independent of the display
/// it happens to be rendered on.
///
/// This is what lets the pixel suites run on CI. `bitmapImageRepForCachingDisplay`
/// sizes its bitmap from the *view's* backing scale, which is the screen's: 2×
/// on a Retina Mac, 1× on a CI VM with no scaler driver, so the same view
/// produced images of different dimensions and could never match — the reason
/// these suites used to be skipped there. Building the bitmap ourselves at a
/// fixed pixel size pins the scale, and `cacheDisplay` draws into it at that
/// resolution.
///
/// `ImageRenderer` would be the tidier spelling and needs no bitmap at all, but
/// it draws SwiftUI only: the launcher's search field, the command palette's
/// text field, the scrolling result lists, and the syntax-highlighted code view
/// all come back as blank or as SwiftUI's yellow "unsupported view" placeholder,
/// which would cost these suites most of what they actually assert.
@MainActor
func capture(_ view: NSView) -> NSImage {
    let bounds = view.bounds
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(bounds.width * snapshotScale),
        pixelsHigh: Int(bounds.height * snapshotScale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        // An empty image fails the comparison with a readable diff, which beats
        // crashing the suite on a force-unwrap.
        return NSImage(size: bounds.size)
    }
    // Points, not pixels: the ratio against `pixelsWide` is what makes the rep
    // 2× and the drawing scale with it.
    rep.size = bounds.size
    view.cacheDisplay(in: bounds, to: rep)
    // Then hand the image back at *pixel* size. A reference PNG carries no
    // scale, so decoding it yields a 1× image of the full pixel dimensions;
    // an image still labelled 2× would never compare equal to its own
    // round-trip, and every assertion would fail against a file it had just
    // written itself.
    let pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    rep.size = pixelSize
    let image = NSImage(size: pixelSize)
    image.addRepresentation(rep)
    return image
}

/// Lay out and capture in one step — what every image assertion uses.
@MainActor
func snapshotImage(
    _ view: some View,
    width: CGFloat,
    height: CGFloat,
    dark: Bool = false
) -> NSImage {
    capture(snapshotHost(view, width: width, height: height, dark: dark))
}

/// Sub-pixel antialiasing drifts across macOS point releases; perceptual
/// precision absorbs it without masking real layout changes.
@MainActor var snapshotImageStrategy: Snapshotting<NSImage, NSImage> {
    .image(precision: 0.99, perceptualPrecision: 0.98)
}

/// Explicit opt-in for changed launcher references; ordinary test runs assert.
@MainActor var snapshotRecordingMode: SnapshotTestingConfiguration.Record {
    ProcessInfo.processInfo.environment["OVERBOARD_RECORD_SNAPSHOTS"] == "1" ? .all : .never
}
