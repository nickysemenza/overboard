import Foundation
@testable import OverboardCore
import Testing

struct QuicklinkProviderTests {
    private static let links = [
        Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}"),
    ]

    private func makeProvider() -> QuicklinkProvider {
        QuicklinkProvider { Self.links }
    }

    @Test func keywordAndQueryBuildsEncodedURL() async {
        let results = await self.makeProvider().results(for: "gh swift grdb")
        guard case let .quicklink(link, query, url)? = results.first else {
            Issue.record("expected a quicklink result")
            return
        }
        #expect(results.count == 1)
        #expect(link.keyword == "gh")
        #expect(query == "swift grdb")
        #expect(url.absoluteString.hasSuffix("q=swift%20grdb"))
    }

    @Test func keywordAloneStripsPlaceholder() async {
        let results = await self.makeProvider().results(for: "gh")
        guard case let .quicklink(_, query, url)? = results.first else {
            Issue.record("expected a quicklink result")
            return
        }
        #expect(query.isEmpty)
        #expect(url.absoluteString == "https://github.com/search?q=")
    }

    @Test func keywordMatchIsCaseInsensitive() async {
        let results = await self.makeProvider().results(for: "GH foo")
        guard case let .quicklink(link, query, _)? = results.first else {
            Issue.record("expected a quicklink result")
            return
        }
        #expect(link.keyword == "gh")
        #expect(query == "foo")
    }

    @Test func unknownKeywordProducesNothing() async {
        let results = await self.makeProvider().results(for: "unknown foo")
        #expect(results.isEmpty)
    }

    @Test func prefixOfKeywordDoesNotMatch() async {
        let results = await self.makeProvider().results(for: "ghx foo")
        #expect(results.isEmpty)
    }

    @Test func emptyQueryProducesNothing() async {
        let results = await self.makeProvider().results(for: "")
        #expect(results.isEmpty)
    }
}
