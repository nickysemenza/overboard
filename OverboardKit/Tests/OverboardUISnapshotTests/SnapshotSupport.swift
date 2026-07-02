import AppKit
import ImageIO
import OverboardCore
import SnapshotTesting
import SwiftUI
import Testing
import UniformTypeIdentifiers

extension Trait where Self == ConditionTrait {
    /// Snapshots are recorded on a local Retina Mac; the CI VM renders at a
    /// different backing scale (no scaler driver), so images can never match.
    /// Asserted locally only.
    static var localOnly: ConditionTrait {
        .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)
    }
}

/// Deterministic fixtures: fixed dates, and bundle IDs that resolve to no
/// installed app so AppIconCache yields the neutral header instead of
/// machine-dependent app icons.
enum Fixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func item(
        kind: ItemKind = .text,
        preview: String,
        appName: String = "Demo Editor",
        isPinned: Bool = false,
        isSecret: Bool = false,
        aiTitle: String? = nil,
        category: String? = nil,
        aiSummary: String? = nil,
        charCount: Int? = nil,
        lineCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        fileCount: Int? = nil,
        linkTitle: String? = nil,
        linkDescription: String? = nil,
        faviconData: Data? = nil,
        previewImageData: Data? = nil
    ) -> ClipItem {
        ClipItem(
            id: "fixture-\(preview.prefix(24))",
            contentHash: "fixture-hash",
            kind: kind,
            previewText: preview,
            sourceBundleID: "dev.example.editor",
            sourceAppName: appName,
            byteSize: preview.utf8.count,
            isPinned: isPinned,
            isSecret: isSecret,
            aiTitle: aiTitle,
            category: category,
            aiSummary: aiSummary,
            createdAt: self.date,
            lastUsedAt: self.date,
            updatedAt: self.date,
            charCount: charCount,
            lineCount: lineCount,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fileCount: fileCount,
            linkTitle: linkTitle,
            linkDescription: linkDescription,
            faviconData: faviconData,
            previewImageData: previewImageData
        )
    }

    /// A tiny solid-color PNG, generated in-memory via ImageIO — no external
    /// fixture files, no AppKit drawing. Stands in for a fetched favicon /
    /// og:image in card snapshots.
    static func solidPNG(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func store() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    static func textSnapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "dev.example.editor",
            sourceAppName: "Demo Editor",
            capturedAt: self.date
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
