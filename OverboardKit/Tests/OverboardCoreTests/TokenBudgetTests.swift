import Foundation
@testable import OverboardCore
import Testing

/// `TokenBudget` never touches FoundationModels — it takes the counter as a
/// closure — so these use a fake, deterministic tokenizer instead of the
/// real on-device model.
struct TokenBudgetTests {
    private actor CallCounter {
        private(set) var count = 0
        func increment() {
            self.count += 1
        }
    }

    /// `ceil(chars / 4)`: bears no resemblance to a real tokenizer, but is
    /// deterministic and cheap, which is all `fit`'s contract needs.
    private func fakeCounter(calls: CallCounter? = nil) -> @Sendable (String) async throws -> Int {
        { text in
            await calls?.increment()
            return Int((Double(text.count) / 4).rounded(.up))
        }
    }

    @Test func underBudgetTextIsUnchanged() async throws {
        let text = "hello world"
        let result = try await TokenBudget.fit(text, budget: 100, count: self.fakeCounter())
        #expect(result == text)
    }

    @Test func overBudgetTextShrinksToFitTheBudget() async throws {
        let text = String(repeating: "a", count: 400)
        let budget = 10
        let result = try await TokenBudget.fit(text, budget: budget, count: self.fakeCounter())
        let resultTokens = Int((Double(result.count) / 4).rounded(.up))
        #expect(resultTokens <= budget)
        #expect(result.count < text.count)
    }

    @Test func zeroBudgetReturnsEmptyStringWithoutCountingText() async throws {
        let calls = CallCounter()
        let result = try await TokenBudget.fit("anything", budget: 0, count: self.fakeCounter(calls: calls))
        #expect(result.isEmpty)
        #expect(await calls.count == 0)
    }

    @Test func negativeBudgetReturnsEmptyString() async throws {
        let result = try await TokenBudget.fit("anything", budget: -5, count: self.fakeCounter())
        #expect(result.isEmpty)
    }

    @Test func neverSplitsAGraphemeCluster() async throws {
        // A family emoji is one `Character` made of several Unicode scalars
        // joined by ZWJ. A byte- or scalar-based cut would slice through it
        // and corrupt the result; `String.prefix(_:)` cuts on `Character`
        // boundaries, so it never does.
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 40)
        let result = try await TokenBudget.fit(text, budget: 5, count: self.fakeCounter())
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0 == Character(family) })
        // The cut landed on a Character boundary: the result is exactly the
        // Character-prefix of the original text at its own length — not a
        // mangled fragment of one.
        #expect(result == String(text.prefix(result.count)))
    }

    @Test func convergesWithinTheRoundBudget() async throws {
        // A counter that never reports the candidate as fitting, however far
        // it shrinks — verifies `fit` terminates instead of looping forever:
        // one initial full-text count plus at most 3 narrowing rounds.
        let calls = CallCounter()
        let neverFits: @Sendable (String) async throws -> Int = { _ in
            await calls.increment()
            return 1000
        }
        let result = try await TokenBudget.fit(String(repeating: "a", count: 1000), budget: 10, count: neverFits)
        #expect(await calls.count == 4)
        #expect(result.count < 1000)
    }
}
