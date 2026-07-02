import CoreGraphics
import Foundation
import ImageIO

/// Memory-frugal image downsizing. `CGImageSourceCreateThumbnailAtIndex`
/// decodes straight to the target size, so a 40 MP screenshot never fully
/// inflates in RAM. Used to cap OCR input and could back cached previews.
public enum ImageDownsampler {
    /// A CGImage no larger than `maxPixel` on its longest side. Returns the
    /// image at native size when it's already within budget. Nil if the data
    /// isn't a decodable image.
    public static func downsampledImage(from data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return self.thumbnail(from: source, maxPixel: maxPixel)
    }

    /// Same as `downsampledImage(from:)` but reads from a file URL, so a large
    /// blob is never fully loaded into memory just to produce a small preview.
    public static func downsampledImage(fromURL url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return self.thumbnail(from: source, maxPixel: maxPixel)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
