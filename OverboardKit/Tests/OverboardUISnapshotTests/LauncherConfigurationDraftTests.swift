import Foundation
import OverboardCore
@testable import OverboardUI
import Testing

struct LauncherConfigurationDraftTests {
    @Test func validatesQuicklinkDestinationsAndKeywords() {
        let draft = LauncherConfigurationDraft(text: """
        # Keep this comment
        docs = Documentation | https://example.com/?q={query}
        DOCS = https://other.example.com
        broken line
        unsafe = javascript:alert(1)
        missing = https://example.com/{unknown}
        """, kind: .quicklinks)
        #expect(draft.issues.map(\.line) == [2, 3, 4, 5])
        #expect(draft.entries.first?.name == "Documentation")
        #expect(draft.entries.first?.destination == "https://example.com/?q={query}")
        #expect(LauncherConfigurationDraft(text: "word = Notes\ntwo words = App\nempty =", kind: .aliases)
            .issues.map(\.line) == [1, 2])
    }

    @Test func structuredEditRetainsInvalidAdvancedLines() throws {
        let text = "# original\nweb = Search | https://example.com/?q={query}\nunfinished line\n"
        let draft = LauncherConfigurationDraft(text: text, kind: .quicklinks)
        var entry = try #require(draft.entries.first)
        entry.name = "Find"
        let edited = draft.replacing(entry)
        #expect(edited == "# original\nweb = Find | https://example.com/?q={query}\nunfinished line\n")
        #expect(LauncherConfigurationDraft(text: edited, kind: .quicklinks).issues.map(\.line) == [2])
        #expect(draft.removing(line: 1) == "# original\nunfinished line\n")
        #expect(draft.removing(line: 99) == text)
    }

    @Test func previewUsesTheCoreExplicitInputContract() throws {
        let link = Quicklink(keyword: "web", name: "Find", template: "https://example.com/?q={clipboard}")
        #expect(link.destination(for: .query("ignored")) == nil)
        let destination = try #require(link.destination(for: .clipboard("a & b")))
        #expect(destination.kind == .web)
        let components = try #require(URLComponents(url: destination.url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first?.value == "a & b")
        #expect(!destination.url.absoluteString.contains("%2526"))
        let application = Quicklink(keyword: "app", name: "App", template: "obsidian://open?vault=Notes")
        #expect(application.destination(for: .query(nil))?.kind == .application)
    }

    @Test func traceAllowsOnlyExactPayloadFreeEvents() {
        #expect(RedactedUITrace.event(for: "launcher.show") == "launcher.show")
        for payload in ["secret query", "launcher.show secret", "launcher.show\nsecret", "/Users/demo/private.txt"] {
            #expect(RedactedUITrace.event(for: payload) == "redacted")
        }
    }
}
