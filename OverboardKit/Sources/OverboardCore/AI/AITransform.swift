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

/// Failure reasons `AITransformer.apply` maps `LanguageModelSession
/// .GenerationError` into, in terms a HUD can show directly instead of a
/// generic "AI transform failed" string.
public enum AIFailure: Error, Sendable, Equatable {
    /// The input (plus instructions) didn't fit the model's context window,
    /// even after `TokenBudget` trimmed it.
    case tooLong
    /// Apple's on-device guardrails refused the content.
    case declined
    /// The text's language isn't one the on-device model supports.
    case unsupportedLanguage
    /// Rate-limited; a transient condition worth retrying.
    case busy
    /// Anything else — including a non-`GenerationError` failure.
    case other

    public var userMessage: String {
        switch self {
        case .tooLong: "Text is too long for on-device AI"
        case .declined: "Apple Intelligence declined this text"
        case .unsupportedLanguage: "Language not supported"
        case .busy: "AI is busy — try again"
        case .other: "AI transform failed"
        }
    }
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
        let instructions = """
        You transform clipboard text for the user. Apply exactly the requested \
        transformation and output ONLY the transformed text — no preamble, no \
        quotes, no commentary.
        """
        let session = LanguageModelSession(instructions: instructions)
        do {
            let input = try await Self.boundedInput(text, instructions: instructions)
            let response = try await session.respond(to: "\(transform.instruction)\n\nText:\n\(input)")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Self.mapFailure(error)
        }
    }

    /// Runs a free-text user instruction (the launcher's "Ask AI" row) over the
    /// clipboard text. Same stateless-session, same token-aware input budget as
    /// the fixed transforms; only the instruction is user-supplied.
    public static func apply(prompt: String, to text: String) async throws -> String {
        let instructions = """
        Apply the user's requested transformation to the text. Return only the \
        transformed text with no preamble, no quotes, and no commentary.
        """
        let session = LanguageModelSession(instructions: instructions)
        do {
            let input = try await Self.boundedInput(text, instructions: instructions)
            let response = try await session.respond(to: "\(prompt)\n\nText:\n\(input)")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Self.mapFailure(error)
        }
    }

    /// Input budget in tokens for a fresh session carrying `instructions`,
    /// available from macOS 26.4 via the back-deployed `contextSize` /
    /// `tokenCount(for:)`.
    @available(macOS 26.4, *)
    private static func availableInputTokens(instructions: String) async throws -> Int {
        let model = SystemLanguageModel.default
        let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
        return model.contextSize - instructionTokens
    }

    /// Trims `text` to fit the model's context window alongside
    /// `instructions`, halving the budget to leave room for the model's own
    /// output (a transform like fixGrammar can echo most of the input back).
    /// Below macOS 26.4 — where `contextSize` / `tokenCount(for:)` aren't
    /// available — falls back to the fixed character cap this used before
    /// token-aware budgeting.
    private static func boundedInput(_ text: String, instructions: String) async throws -> String {
        if #available(macOS 26.4, *) {
            let available = try await Self.availableInputTokens(instructions: instructions)
            let model = SystemLanguageModel.default
            return try await TokenBudget.fit(text, budget: available / 2) { try await model.tokenCount(for: $0) }
        }
        return String(text.prefix(6000))
    }

    /// Maps a thrown `LanguageModelSession.GenerationError` to the HUD-facing
    /// `AIFailure` it corresponds to; any other error (including one already
    /// surfaced by `boundedInput`) becomes `.other`.
    private static func mapFailure(_ error: Error) -> AIFailure {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return .other
        }
        switch generationError {
        case .exceededContextWindowSize: return .tooLong
        case .guardrailViolation: return .declined
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        case .rateLimited: return .busy
        default: return .other
        }
    }
}
