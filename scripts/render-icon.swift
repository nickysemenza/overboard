// Renders the Overboard app icon: ocean-gradient macOS squircle + sailboat.
// Usage: swift scripts/render-icon.swift <output-dir>
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/overboard-icon"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func renderIcon(canvas: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        let scale = canvas / 1024.0

        // macOS icon grid: ~824pt rounded rect centered in 1024 canvas.
        let inset = 100.0 * scale
        let rect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
        let radius = 186.0 * scale
        let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // Deep-ocean vertical gradient.
        let top = NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.62, alpha: 1)
        let bottom = NSColor(calibratedRed: 0.04, green: 0.15, blue: 0.30, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: squircle, angle: -90)

        // Subtle wave bands across the lower third.
        NSGraphicsContext.current?.saveGraphicsState()
        squircle.addClip()
        let waveColor = NSColor.white.withAlphaComponent(0.10)
        for (i, yFactor) in [0.30, 0.24, 0.18].enumerated() {
            let wave = NSBezierPath()
            let y = rect.minY + rect.height * yFactor
            let amplitude = (14.0 - Double(i) * 3) * scale
            wave.move(to: NSPoint(x: rect.minX, y: y))
            let segments = 4
            let width = rect.width / CGFloat(segments)
            for segment in 0 ..< segments {
                let startX = rect.minX + CGFloat(segment) * width
                wave.curve(
                    to: NSPoint(x: startX + width, y: y),
                    controlPoint1: NSPoint(x: startX + width * 0.33, y: y + amplitude),
                    controlPoint2: NSPoint(x: startX + width * 0.66, y: y - amplitude)
                )
            }
            wave.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            wave.line(to: NSPoint(x: rect.minX, y: rect.minY))
            wave.close()
            waveColor.setFill()
            wave.fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        // The boat.
        let config = NSImage.SymbolConfiguration(pointSize: 430 * scale, weight: .medium)
        if let symbol = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        {
            let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
                symbol.draw(in: drawRect)
                NSColor.white.set()
                drawRect.fill(using: .sourceAtop)
                return true
            }
            let symbolSize = tinted.size
            let origin = NSPoint(
                x: rect.midX - symbolSize.width / 2,
                y: rect.midY - symbolSize.height / 2 + rect.height * 0.06
            )
            // Soft shadow so the boat sits on the water.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 18 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
            NSGraphicsContext.current?.saveGraphicsState()
            shadow.set()
            tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        return true
    }
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for size in sizes {
    // Fresh image per size — NSImage caches its first rasterization, so
    // reusing one master would upscale whichever size rendered first.
    let image = renderIcon(canvas: CGFloat(size.pixels))
    writePNG(image, pixels: size.pixels, to: "\(outputDir)/\(size.name).png")
}
print("wrote \(sizes.count) pngs to \(outputDir)")
