import CoreText
import Foundation

/// Answers "can this OS actually draw this emoji?" — the `isRenderable` gate
/// EmojiCatalog uses to hide emoji newer than the installed Apple Color Emoji
/// font (which would otherwise render as tofu or a decomposed ZWJ sequence).
public enum EmojiRenderCheck {
    /// A supported emoji lays out as a single glyph cluster in Apple Color
    /// Emoji. Unsupported ones either fall back to another font (lone
    /// unsupported scalars) or split into multiple glyphs (unsupported ZWJ
    /// sequences decompose into their parts, unsupported flags into two
    /// regional-indicator letters) — both show up as glyphCount > 1 or a
    /// non-emoji run font.
    public static func canRender(_ emoji: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)
        let attributed = NSAttributedString(string: emoji, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        guard CTLineGetGlyphCount(line) == 1,
              let runs = CTLineGetGlyphRuns(line) as? [CTRun],
              runs.count == 1,
              let run = runs.first
        else { return false }

        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let runFontValue = attributes[kCTFontAttributeName as String] else { return false }
        // CTRun attribute values are CF objects; CTFont is toll-free usable here.
        let runFont = runFontValue as! CTFont // swiftlint:disable:this force_cast
        let name = CTFontCopyPostScriptName(runFont) as String
        return name == "AppleColorEmoji"
    }
}
