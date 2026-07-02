import Foundation
@testable import OverboardCore
import Testing

struct AskAIProviderTests {
    private static let available = AskAIProvider(isAvailable: { true })
    private static let unavailable = AskAIProvider(isAvailable: { false })

    /// The gate wins outright: even a perfectly qualifying query stays dark when
    /// the model is unavailable (tests/previews inject `false`).
    @Test func availabilityGateOffYieldsNothing() async {
        #expect(await Self.unavailable.results(for: "summarize this text").isEmpty)
    }

    /// Too short to read as an instruction — a lookup, not a prompt.
    @Test func shortQueryYieldsNothing() async {
        #expect(await Self.available.results(for: "fix it").isEmpty)
    }

    /// A single long word is a search term, not an instruction; require a space.
    @Test func singleWordQueryYieldsNothing() async {
        #expect(await Self.available.results(for: "supercalifragilistic").isEmpty)
    }

    /// ":"-prefixed queries are launcher commands — never an AI prompt.
    @Test func colonPrefixYieldsNothing() async {
        #expect(await Self.available.results(for: ":summarize the clipboard").isEmpty)
    }

    /// Available + long enough + multi-word + not a command → exactly one row,
    /// carrying the trimmed prompt.
    @Test func qualifyingQueryYieldsOneRow() async {
        let results = await Self.available.results(for: "make this more concise")
        #expect(results == [.askAI(prompt: "make this more concise")])
    }

    /// Leading/trailing whitespace is trimmed before both the gates and the row
    /// (so a padded-out short query still fails the length check).
    @Test func queryIsTrimmedBeforeGatesAndRow() async {
        #expect(await Self.available.results(for: "   fix it   ").isEmpty)
        let results = await Self.available.results(for: "  translate to french  ")
        #expect(results == [.askAI(prompt: "translate to french")])
    }
}
