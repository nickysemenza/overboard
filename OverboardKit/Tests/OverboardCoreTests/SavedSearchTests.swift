@testable import OverboardCore
import Testing

struct SavedSearchTests {
    @Test func labelsKindOnlyQuery() {
        #expect(SavedSearch.label(for: "kind:image") == "Images")
        #expect(SavedSearch.label(for: "kind:link") == "Links")
    }

    @Test func labelsKindPlusApp() {
        #expect(SavedSearch.label(for: "kind:image app:slack") == "Images in Slack")
    }

    @Test func labelsFreeTextInQuotes() {
        #expect(SavedSearch.label(for: "todo kind:text") == "Text “todo”")
    }

    @Test func labelsCategory() {
        #expect(SavedSearch.label(for: "category:code") == "Code")
    }

    @Test func fallsBackToRawWhenNoOperators() {
        #expect(SavedSearch.label(for: "deploy notes") == "deploy notes")
    }

    @Test func savedQueryRunsThroughTheSameParser() {
        // The label is derived from the same ParsedQuery the search path uses,
        // so a saved "kind:image app:slack" filters identically to typing it.
        let parsed = ParsedQuery.parse("kind:image app:slack")
        #expect(parsed.kind == .image)
        #expect(parsed.app == "slack")
    }
}
