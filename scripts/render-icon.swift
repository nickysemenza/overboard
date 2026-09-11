// Renders the foreground layer PNGs for Overboard's Liquid Glass app icon
// (Overboard/Overboard.icon): translucent wave bands + a sailboat glyph.
// The deep-ocean background is a gradient `fill` declared directly in
// icon.json, so this script only needs to emit the two foreground layers —
// each a full 1024x1024 canvas, transparent outside the drawn artwork, so
// Icon Composer/actool can clip and light them per-platform on their own.
// Usage: swift scripts/render-icon.swift <icon-bundle-dir>
import AppKit

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Overboard/Overboard.icon"
let assetsDir = "\(outputDir)/Assets"
try? FileManager.default.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)

let canvas: CGFloat = 1024
// macOS icon grid: ~824pt content rect centered in the 1024 canvas. Used only
// to position artwork within the layer — the platform squircle mask and
// glass compositing are applied by the system at render time, not baked in
// here.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)

/// The water fills the whole canvas below each crest: the platform mask clips
/// it to the squircle, so stopping at the content rect would leave a visible
/// rectangle floating inside the icon.
func renderWaves() -> NSImage {
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        let waveColor = NSColor.white.withAlphaComponent(0.12)
        for (i, yFactor) in [0.30, 0.24, 0.18].enumerated() {
            let wave = NSBezierPath()
            let y = rect.minY + rect.height * yFactor
            let amplitude = 14.0 - Double(i) * 3
            wave.move(to: NSPoint(x: 0, y: y))
            let segments = 5
            let width = canvas / CGFloat(segments)
            for segment in 0 ..< segments {
                let startX = CGFloat(segment) * width
                wave.curve(
                    to: NSPoint(x: startX + width, y: y),
                    controlPoint1: NSPoint(x: startX + width * 0.33, y: y + amplitude),
                    controlPoint2: NSPoint(x: startX + width * 0.66, y: y - amplitude)
                )
            }
            wave.line(to: NSPoint(x: canvas, y: 0))
            wave.line(to: NSPoint(x: 0, y: 0))
            wave.close()
            waveColor.setFill()
            wave.fill()
        }
        return true
    }
}

func renderBoat() -> NSImage {
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return true }

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
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()
        return true
    }
}

func writePNG(_ image: NSImage, to path: String) {
    let pixels = Int(canvas)
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

writePNG(renderWaves(), to: "\(assetsDir)/Waves.png")
writePNG(renderBoat(), to: "\(assetsDir)/Boat.png")

print("wrote 2 layer pngs to \(assetsDir)")
