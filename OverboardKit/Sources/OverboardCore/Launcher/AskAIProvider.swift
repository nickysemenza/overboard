import Foundation

/// The launcher's "Ask AI" fallback: when the query reads like a natural-language
/// instruction rather than a lookup, offer to run it as a custom Apple
/// Intelligence prompt over the current clipboard text.
///
/// Deliberately conservative so it never crowds real results — it only fires
/// when the model is available and the query is long enough (>= 12 chars),
/// multi-word (contains a space), and not a ":"-prefixed command. `isAvailable`
/// is injected (rather than read here) so OverboardCore stays free of the
/// FoundationModels + Defaults gate, and tests/previews leave it dark.
public struct AskAIProvider: LauncherProvider {
    private let isAvailable: @Sendable () -> Bool

    public init(isAvailable: @escaping @Sendable () -> Bool) {
        self.isAvailable = isAvailable
    }

    public func results(for query: String) async -> [LauncherResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.isAvailable(),
              trimmed.count >= 12,
              trimmed.contains(" "),
              !trimmed.hasPrefix(":")
        else { return [] }
        return [.askAI(prompt: trimmed)]
    }
}
