import AppKit
import Highlightr

/// Shared, cached Highlightr instance. Constructing a `Highlightr` boots a JS
/// engine (~100ms), so every caller — `OverboardFilePreview`'s own file
/// preview and `OverboardUI`'s `CodeHighlighter` — shares this one cache
/// instead of each paying that cost separately.
///
/// `Highlightr` itself isn't `Sendable`, so every access (synchronous or
/// asynchronous) is funneled through one serial `DispatchQueue` rather than
/// an actor: `FilePreviewView.swift`'s `HighlightrMarkdownSyntaxHighlighter`
/// must return a value inline (MarkdownUI's `CodeSyntaxHighlighter` protocol
/// has no async hook), which a serial queue can do via a blocking `sync` call
/// in a way an actor cannot. The queue guarantees only one highlight pass
/// ever touches the cached instance at a time, whichever entry point it came
/// through.
public final nonisolated class HighlightrCache: @unchecked Sendable {
    public static let shared = HighlightrCache()

    private let queue = DispatchQueue(label: "com.nickysemenza.overboard.highlightr")
    private var cached: Highlightr?
    private var cachedThemeIsDark: Bool?

    private init() {}

    /// Async entry point: runs the highlight on the shared serial queue (off
    /// the caller's actor) and resumes with the result. Use this wherever the
    /// call site can await — it's what keeps highlighting off the main thread.
    public func highlight(_ code: String, language: String? = nil, dark: Bool) async -> NSAttributedString? {
        await withCheckedContinuation { continuation in
            self.queue.async {
                continuation.resume(returning: self.perform(code, language: language, dark: dark))
            }
        }
    }

    /// Synchronous entry point for callers that cannot await (MarkdownUI's
    /// `CodeSyntaxHighlighter`). Blocks the calling thread briefly while the
    /// shared queue performs the highlight.
    public func highlightSync(_ code: String, language: String? = nil, dark: Bool) -> NSAttributedString? {
        self.queue.sync { self.perform(code, language: language, dark: dark) }
    }

    /// Always runs on `queue` — never call directly from outside it.
    private func perform(_ code: String, language: String?, dark: Bool) -> NSAttributedString? {
        guard let highlightr = self.instance(dark: dark) else { return nil }
        return language.flatMap { highlightr.highlight(code, as: $0) } ?? highlightr.highlight(code)
    }

    /// Always runs on `queue` — never call directly from outside it.
    private func instance(dark: Bool) -> Highlightr? {
        if let cached, self.cachedThemeIsDark == dark {
            return cached
        }
        guard let highlightr = self.cached ?? Highlightr() else { return nil }
        highlightr.setTheme(to: dark ? "atom-one-dark" : "xcode")
        highlightr.theme.codeFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
        self.cached = highlightr
        self.cachedThemeIsDark = dark
        return highlightr
    }
}
