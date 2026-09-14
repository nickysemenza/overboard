import Foundation
@testable import OverboardCore
import Testing

struct QuicklinkTests {
    @Test func parsesBareForm() {
        let links = Quicklink.parse("gh = https://github.com/search?q={query}")
        #expect(links.count == 1)
        #expect(links.first?.keyword == "gh")
        #expect(links.first?.name == "github.com")
        #expect(links.first?.template == "https://github.com/search?q={query}")
    }

    @Test func parsesNamedForm() {
        let links = Quicklink.parse("gh = GitHub | https://github.com/search?q={query}")
        #expect(links.first?.name == "GitHub")
        #expect(links.first?.keyword == "gh")
    }

    @Test func nameDefaultsToHostMinusWWW() {
        let links = Quicklink.parse("nyt = https://www.nytimes.com/search?query={query}")
        #expect(links.first?.name == "nytimes.com")
    }

    @Test func commentsAndBlankLinesAreSkipped() {
        let raw = """
        # a comment
        gh = https://github.com/search?q={query}

        # another comment
        """
        let links = Quicklink.parse(raw)
        #expect(links.count == 1)
        #expect(links.first?.keyword == "gh")
    }

    @Test func malformedLinesAreSkipped() {
        let raw = """
        no equals sign here
        = missingkeyword
        gh =
        gh2 = https://github.com
        """
        let links = Quicklink.parse(raw)
        #expect(links.map(\.keyword) == ["gh2"])
    }

    @Test func laterDuplicateWins() {
        let raw = """
        gh = https://github.com
        gh = https://github.com/search?q={query}
        """
        let links = Quicklink.parse(raw)
        #expect(links.count == 1)
        #expect(links.first?.template == "https://github.com/search?q={query}")
    }

    @Test func keywordIsFoldedCaseInsensitive() {
        let links = Quicklink.parse("GH = https://github.com/search?q={query}")
        #expect(links.first?.keyword == "gh")
    }

    @Test func urlForQueryEncodesLikeWebSearch() {
        let link = Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}")
        let url = link.url(for: "c++ grdb")
        #expect(url?.absoluteString == "https://github.com/search?q=c%2B%2B%20grdb")
    }

    @Test func nilQueryStripsPlaceholder() {
        let link = Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}")
        let url = link.url(for: nil)
        #expect(url?.absoluteString == "https://github.com/search?q=")
    }

    @Test func emptyQueryAlsoStripsPlaceholder() {
        let link = Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}")
        let url = link.url(for: "")
        #expect(url?.absoluteString == "https://github.com/search?q=")
    }

    @Test func templateWithoutPlaceholderIsUnaffectedByQuery() {
        let link = Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com")
        #expect(link.url(for: "anything")?.absoluteString == "https://github.com")
        #expect(link.url(for: nil)?.absoluteString == "https://github.com")
    }

    @Test func emptyInputParsesToNoLinks() {
        #expect(Quicklink.parse("").isEmpty)
        #expect(Quicklink.parse("   \n  \n").isEmpty)
    }
}
