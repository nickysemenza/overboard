import AppIntents
import AppKit
import OverboardCore

/// Thrown when a `SnippetEntity` passed to `CopySnippetIntent` no longer
/// exists in the store (deleted between selection and running the shortcut).
enum CopySnippetIntentError: LocalizedError {
    case notFound

    var errorDescription: String? {
        "That snippet no longer exists."
    }
}

/// Copies a saved snippet's expanded body to the clipboard.
struct CopySnippetIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Snippet"
    static let description = IntentDescription(
        "Expands a saved Overboard snippet's placeholders and copies the result to the clipboard."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Snippet", description: "The snippet to copy")
    var snippet: SnippetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Copy snippet \(\.$snippet)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let deps = IntentDependencies.current
        guard let full = try await deps.store.snippets().first(where: { $0.id == self.snippet.id })
        else {
            throw CopySnippetIntentError.notFound
        }

        // Same expansion + copy path as the launcher's onCopySnippet: read
        // {clipboard} before it's overwritten, then hand the result to the
        // shared marker-tagged copy helper.
        let clipboard = NSPasteboard.general.string(forType: .string)
        let expanded = SnippetTemplate.expand(full.body, clipboard: clipboard)
        deps.copyString(expanded, "Snippet copied — ⌘V to paste")
        return .result(value: expanded)
    }
}
