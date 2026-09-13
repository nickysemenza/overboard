import AppKit
import OverboardFilePreview
import SwiftUI

/// Syntax highlighting for code clips in the preview pane, via highlight.js
/// (JavaScriptCore — fully local). Delegates to `HighlightrCache`
/// (`OverboardFilePreview`) so this and the file-preview path share one
/// cached instance (~100ms to boot) and run off the caller's actor via that
/// cache's serial queue.
enum CodeHighlighter {
    /// Inputs are capped so a pathological clip can't stall the preview.
    private static let maxLength = 12000

    static func highlight(_ code: String, dark: Bool) async -> NSAttributedString? {
        let capped = String(code.prefix(self.maxLength))
        // No language hint: highlight.js auto-detection.
        return await HighlightrCache.shared.highlight(capped, dark: dark)
    }

    /// Cheap fallback for when the AI categorizer hasn't run (or is off):
    /// multi-line content with a couple of code-shaped markers.
    nonisolated static func looksLikeCode(_ text: String) -> Bool {
        guard text.contains("\n") else { return false }
        let markers = [
            "func ", "def ", "class ", "import ", "#include", "const ",
            "let ", "var ", "fn ", "return ", "=> ", "if (", "for (",
            "public ", "private ", "});",
        ]
        let hits = markers.count(where: text.contains)
        if hits >= 2 {
            return true
        }
        return hits >= 1 && text.contains("{") && text.contains("}")
    }
}

/// Non-editable NSTextView host — SwiftUI's Text doesn't reliably render
/// AppKit-scope attributes from highlight.js output, and NSTextView gives us
/// selection and scrolling for free.
struct CodeTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    var selectable = true

    func makeNSView(context _: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        // scrollableTextView()'s documentView is an NSTextView by API contract.

        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = self.selectable
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = self.selectable
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context _: Context) {
        // scrollableTextView()'s documentView is an NSTextView by API contract.

        let textView = scroll.documentView as! NSTextView
        textView.textStorage?.setAttributedString(self.attributed)
    }
}
