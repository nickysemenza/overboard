import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// LLM-powered paste transforms ("Paste with AI" in the card context menu).
/// Runs entirely on-device via Apple's Foundation Models framework.
public enum AITransform: String, Sendable, CaseIterable, Identifiable {
    case summarize
    case fixGrammar
    case makeFormal
    case makeCasual
    case extractActionItems

    public var id: String {
        self.rawValue
    }

    public var label: String {
        switch self {
        case .summarize: "Summarize"
        case .fixGrammar: "Fix Grammar & Spelling"
        case .makeFormal: "Make Formal"
        case .makeCasual: "Make Casual"
        case .extractActionItems: "Extract Action Items"
        }
    }

    var instruction: String {
        switch self {
        case .summarize:
            "Summarize the text concisely, keeping the key facts."
        case .fixGrammar:
            """
            Fix all grammar, spelling, and punctuation mistakes in the text. Keep the wording \
            and tone otherwise unchanged.
            """
        case .makeFormal:
            "Rewrite the text in a polished, professional tone."
        case .makeCasual:
            "Rewrite the text in a relaxed, casual tone."
        case .extractActionItems:
            """
            Extract the action items from the text as a short dash-prefixed list. If there are \
            none, reply with the single line: No action items.
            """
        }
    }
}

/// What the on-device model reports, in the terms Settings can act on.
public enum AIAvailability: Sendable, Equatable {
    case available
    /// Apple Intelligence is off in System Settings — the user can fix this.
    case notEnabled
    /// Model assets are still downloading; transient.
    case modelNotReady
    /// Not an eligible Mac, or a reason this build doesn't know.
    case unsupported
}

public enum AITransformer {
    /// What the on-device model reports right now. `isAvailable` is the
    /// yes/no most call sites want; Settings shows the finer detail so the
    /// user knows whether to open System Settings or just wait.
    public static var availability: AIAvailability {
        #if canImport(FoundationModels)
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .notEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                return .unsupported
            }
        #else
            return .unsupported
        #endif
    }

    /// True when the on-device model is ready (Apple Silicon with Apple
    /// Intelligence enabled).
    public static var isAvailable: Bool {
        self.availability == .available
    }

    public static func apply(_ transform: AITransform, to text: String) async throws -> String {
        // Fresh session per request: sessions accumulate transcript context,
        // and each transform should be stateless.
        let session = LanguageModelSession(instructions: """
        You transform clipboard text for the user. Apply exactly the requested \
        transformation and output ONLY the transformed text — no preamble, no \
        quotes, no commentary.
        """)
        let input = String(text.prefix(6000))
        let response = try await session.respond(to: "\(transform.instruction)\n\nText:\n\(input)")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a free-text user instruction (the launcher's "Ask AI" row) over the
    /// clipboard text. Same stateless-session, same 6000-char input cap as the
    /// fixed transforms; only the instruction is user-supplied.
    public static func apply(prompt: String, to text: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Apply the user's requested transformation to the text. Return only the \
        transformed text with no preamble, no quotes, and no commentary.
        """)
        let input = String(text.prefix(6000))
        let response = try await session.respond(to: "\(prompt)\n\nText:\n\(input)")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
