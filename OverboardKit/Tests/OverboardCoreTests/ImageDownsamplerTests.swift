import CoreGraphics
import Foundation
import ImageIO
@testable import OverboardCore
import Testing
import UniformTypeIdentifiers

struct ImageDownsamplerTests {
    /// Builds an opaque PNG of the given pixel dimensions.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try #require(context.makeImage())

        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(dest, cgImage, nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @Test func capsLongestSideToMaxPixel() throws {
        let png = try makePNG(width: 1000, height: 600)
        let down = try #require(ImageDownsampler.downsampledImage(from: png, maxPixel: 100))
        #expect(max(down.width, down.height) <= 100)
        // Aspect ratio preserved: 1000x600 → ~100x60.
        #expect(down.width == 100)
        #expect(down.height == 60)
    }

    @Test func smallImageStaysWithinBudget() throws {
        let png = try makePNG(width: 80, height: 40)
        let down = try #require(ImageDownsampler.downsampledImage(from: png, maxPixel: 4096))
        #expect(max(down.width, down.height) <= 4096)
    }

    @Test func fromURLMatchesFromData() throws {
        let png = try makePNG(width: 800, height: 400)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downsample-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromURL = try #require(ImageDownsampler.downsampledImage(fromURL: url, maxPixel: 200))
        #expect(fromURL.width == 200)
        #expect(fromURL.height == 100)
    }

    @Test func nonImageDataReturnsNil() {
        #expect(ImageDownsampler.downsampledImage(from: Data("not an image".utf8), maxPixel: 100) == nil)
    }
}
