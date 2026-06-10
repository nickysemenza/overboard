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

    @available(macOS 26.0, *)
    public static func enrich(text: String) async throws -> Enrichment {
        let session = LanguageModelSession(instructions: """
        You label clipboard snippets. Generate a short descriptive title \
        (2-5 words), pick the single best category, and write a one-sentence \
        summary of the snippet's content.
        """)
        let input = String(text.prefix(3000))
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
}

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    private struct GeneratedLabel {
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
