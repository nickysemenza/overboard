import AppIntents
import OverboardCore

/// Finds the best match for a query in clipboard history and returns its
/// plain text (or the closest text Overboard has for it) without touching the
/// pasteboard.
struct SearchClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Clipboard History"
    static let description = IntentDescription(
        "Searches your Overboard clipboard history and returns the best-matching item's text."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Search Text")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search clipboard history for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = IntentDependencies.current.store
        // The store's own FTS/frecency search; a few extra results are pulled
        // so a secret sitting above the true best (text) match doesn't block it.
        let results = try await store.search(self.query, limit: ClipLookup.searchScanLimit)
        guard let item = ClipLookup.firstUsable(in: results) else {
            return .result(value: "", dialog: "No matching clip found in Overboard")
        }

        let text = try? await store.plainText(for: item.id)
        return .result(
            value: ClipLookup.resultText(plainText: text, fallback: item.previewText),
            dialog: "Found a match in Overboard"
        )
    }
}
