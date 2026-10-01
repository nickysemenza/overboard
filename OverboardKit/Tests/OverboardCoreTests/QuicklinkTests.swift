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

    @Test func explicitClipboardInputIsEncodedExactlyOnce() {
        let link = Quicklink(keyword: "find", name: "Find", template: "https://example.com/?q={clipboard}")
        #expect(link.destination(for: .query("ambient")) == nil)
        let destination = link.destination(for: .clipboard("c++ & 100% / café"))
        #expect(destination?.kind == .web)
        #expect(destination?.url.absoluteString == "https://example.com/?q=c%2B%2B%20%26%20100%25%20%2F%20caf%C3%A9")
    }

    @Test func encodedLookingInputRemainsLiteralInput() {
        let link = Quicklink(keyword: "find", name: "Find", template: "https://example.com/?q={query}")
        #expect(link.destination(for: .query("%2F"))?.url.absoluteString == "https://example.com/?q=%252F")
    }

    @Test func applicationDestinationIsExplicit() {
        let link = Quicklink(keyword: "app", name: "App", template: "obsidian://open?vault={query}")
        #expect(link.destination(for: .query("My Notes"))?.kind == .application)
        #expect(link.destination(for: .query("My Notes"))?.url.absoluteString == "obsidian://open?vault=My%20Notes")
    }

    @Test func serializationPreservesLegacyEditorRows() {
        let links = Quicklink.parse("""
        gh = GitHub | https://github.com/search?q={query}
        wiki = https://example.com/wiki
        """)
        #expect(Quicklink.parse(Quicklink.serialize(links)) == links)
    }

    @Test func unsafeOrUnsupportedTemplatesHaveValidationIssues() {
        #expect(!Quicklink.validationIssues(for: "javascript:{query}").isEmpty)
        #expect(!Quicklink.validationIssues(for: "https://example.com/{unknown}").isEmpty)
        #expect(!Quicklink.validationIssues(for: "https://{query}/").isEmpty)
        #expect(!Quicklink.validationIssues(for: "https://example.com/{query").isEmpty)
        #expect(Quicklink.validationIssues(for: "https://example.com/?q={clipboard}").isEmpty)
    }

    @Test func legacyQueryEntryPointUsesValidatedDestination() {
        let unsafe = Quicklink(keyword: "unsafe", name: "Unsafe", template: "javascript:{query}")
        let clipboard = Quicklink(keyword: "clip", name: "Clip", template: "https://example.com/?q={clipboard}")
        #expect(unsafe.url(for: "alert(1)") == nil)
        #expect(clipboard.url(for: "ambient") == nil)
    }
}
