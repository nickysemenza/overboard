@testable import OverboardCore
import Testing

/// `AIFailure.userMessage` is the only piece of this the HUD-facing code
/// touches directly; the `GenerationError` → `AIFailure` mapping itself
/// isn't tested here because `LanguageModelSession.GenerationError`'s cases
/// aren't constructible from test code without a live model session.
struct AIFailureTests {
    @Test func everyCaseHasANonEmptyMessage() {
        for failure in [AIFailure.tooLong, .declined, .unsupportedLanguage, .busy, .other] {
            #expect(!failure.userMessage.isEmpty)
        }
    }

    @Test func everyCaseHasADistinctMessage() {
        let messages = [AIFailure.tooLong, .declined, .unsupportedLanguage, .busy, .other]
            .map(\.userMessage)
        #expect(Set(messages).count == messages.count)
    }
}
