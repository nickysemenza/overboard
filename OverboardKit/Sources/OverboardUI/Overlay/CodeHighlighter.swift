import AppKit
import Highlightr
import SwiftUI

/// Syntax highlighting for code clips in the preview pane, via highlight.js
/// (JavaScriptCore — fully local). The Highlightr instance is cached because
/// loading the JS engine costs ~100ms.
@MainActor
enum CodeHighlighter {
    /// Inputs are capped so a pathological clip can't stall the preview.
    private static let maxLength = 12000

    private static var cached: Highlightr?
    private static var cachedThemeIsDark: Bool?

    static func highlight(_ code: String, dark: Bool) -> NSAttributedString? {
        guard let highlightr = instance(dark: dark) else { return nil }
        let capped = String(code.prefix(self.maxLength))
        // No language hint: highlight.js auto-detection.
        return highlightr.highlight(capped)
    }

    private static func instance(dark: Bool) -> Highlightr? {
        if let cached, self.cachedThemeIsDark == dark { return cached }
        guard let highlightr = self.cached ?? Highlightr() else { return nil }
        highlightr.setTheme(to: dark ? "atom-one-dark" : "xcode")
        highlightr.theme.codeFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
        self.cached = highlightr
        self.cachedThemeIsDark = dark
        return highlightr
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
        if hits >= 2 { return true }
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
        // swiftlint:disable:next force_cast
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
        // swiftlint:disable:next force_cast
        let textView = scroll.documentView as! NSTextView
        textView.textStorage?.setAttributedString(self.attributed)
    }
}
