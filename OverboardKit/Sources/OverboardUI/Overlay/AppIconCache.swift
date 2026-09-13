import AppKit
import SwiftUI

/// Resolves and caches app icons by bundle ID. Icons are looked up lazily —
/// we never persist them. Backed by `NSCache` (rather than a plain
/// dictionary) so the icon/tint caches can be evicted under memory pressure
/// instead of growing for the life of the process.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    /// `NSCache` needs a reference-type value; wraps the (possibly-nil)
    /// lookup result so a bundle ID known to have no icon/tint stays
    /// distinguishable from one never looked up.
    private final class IconBox {
        let image: NSImage?
        init(_ image: NSImage?) {
            self.image = image
        }
    }

    private final class TintBox {
        let color: Color?
        init(_ color: Color?) {
            self.color = color
        }
    }

    private let iconCache = NSCache<NSString, IconBox>()
    private let tintCache = NSCache<NSString, TintBox>()

    func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        let key = bundleID as NSString
        if let boxed = self.iconCache.object(forKey: key) {
            return boxed.image
        }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        self.iconCache.setObject(IconBox(icon), forKey: key)
        return icon
    }

    /// Dominant color of the app's icon (average pixel), for tinted headers.
    func tint(forBundleID bundleID: String?) -> Color? {
        guard let bundleID else { return nil }
        let key = bundleID as NSString
        if let boxed = self.tintCache.object(forKey: key) {
            return boxed.color
        }
        let tint = self.icon(forBundleID: bundleID).flatMap(Self.averageColor)
        self.tintCache.setObject(TintBox(tint), forKey: key)
        return tint
    }

    private static func averageColor(of image: NSImage) -> Color? {
        guard let context = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let pixel = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let alpha = Double(pixel[3]) / 255
        guard alpha > 0.1 else { return nil }
        // Un-premultiply so transparent icon edges don't darken the tint.
        return Color(
            red: Double(pixel[0]) / 255 / alpha,
            green: Double(pixel[1]) / 255 / alpha,
            blue: Double(pixel[2]) / 255 / alpha
        )
    }
}
