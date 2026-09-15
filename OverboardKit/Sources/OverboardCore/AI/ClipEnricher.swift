import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Background enrichment for clips: a short human-readable title and a
/// category, generated on-device. Best-effort — clips work fine without it.
public enum ClipEnricher {
    public struct Enrichment: Sendable {
        public let title: String
        public let category: String
        public let summary: String
    }

    /// Below this many input characters a summary adds nothing over the raw
    /// preview, so it isn't stored or displayed.
    public static let summaryWorthwhileLength = 250

    /// Categories worth surfacing as a badge on the card.
    public static let badgeCategories: Set<String> = ["code", "error", "address", "contact", "list"]

    public static var isAvailable: Bool {
        AITransformer.isAvailable
    }

    public static func enrich(text: String) async throws -> Enrichment {
        let instructions = """
        You label clipboard snippets. Generate a short descriptive title \
        (2-5 words), pick the single best category, and write a one-sentence \
        summary of the snippet's content.
        """
        let session = LanguageModelSession(instructions: instructions)
        let input = try await Self.boundedInput(text, instructions: instructions)
        let response = try await session.respond(
            to: "Label this clipboard snippet:\n\(input)",
            generating: GeneratedLabel.self
        )
        let label = response.content
        return Enrichment(
            title: label.title.trimmingCharacters(in: .whitespacesAndNewlines),
            category: String(describing: label.category),
            summary: label.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Trims `text` to fit the model's context window alongside
    /// `instructions` and the `GeneratedLabel` output schema. Below macOS
    /// 26.4 — where `contextSize` / `tokenCount(for:)` aren't available —
    /// falls back to the fixed character cap this used before token-aware
    /// budgeting.
    private static func boundedInput(_ text: String, instructions: String) async throws -> String {
        if #available(macOS 26.4, *) {
            let model = SystemLanguageModel.default
            let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
            let schemaTokens = try await model.tokenCount(for: GeneratedLabel.generationSchema)
            let budget = model.contextSize - instructionTokens - schemaTokens - 512
            return try await TokenBudget.fit(text, budget: budget) { try await model.tokenCount(for: $0) }
        }
        return String(text.prefix(3000))
    }
}

#if canImport(FoundationModels)
    @Generable
    struct GeneratedLabel {
        @Guide(description: "A short descriptive title, 2-5 words")
        var title: String

        @Guide(description: "The category that best describes the snippet")
        var category: Category

        @Guide(description: "A single plain sentence (max 25 words) summarizing the snippet")
        var summary: String

        @Generable
        enum Category {
            case code
            case error
            case address
            case contact
            case prose
            case list
            case other
        }
    }
#endif
