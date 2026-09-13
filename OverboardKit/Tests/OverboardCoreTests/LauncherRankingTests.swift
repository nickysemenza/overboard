import Foundation
@testable import OverboardCore
import Testing

struct LauncherRankingTests {
    @Test func exactFileBeatsWeakAppRegardlessOfProviderOrder() {
        let app = LauncherResult.app(
            name: "Say Hello Utility",
            url: URL(fileURLWithPath: "/Applications/Say Hello Utility.app")
        )
        let file = LauncherResult.file(name: "hello", url: URL(fileURLWithPath: "/tmp/hello"))
        #expect(LauncherRanking.sorted([app, file], query: "hello").first == file)
    }

    @Test func learningCannotOutrankBetterMatchTier() {
        let weak = LauncherResult.app(name: "Hello Helper", url: URL(fileURLWithPath: "/Applications/Hello Helper.app"))
        let exact = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        #expect(LauncherRanking.sorted([weak, exact], query: "hello", usage: [weak.id: 100]).first == exact)
        let peer = LauncherResult.file(name: "hello.md", url: URL(fileURLWithPath: "/tmp/hello.md"))
        #expect(LauncherRanking.sorted([exact, peer], query: "hello", usage: [peer.id: 2]).first == peer)
    }

    @Test func pathWordsAndTyposMatch() {
        #expect(SearchMatcher.match(
            query: "wedding budget",
            title: "2026 budget.xlsx",
            context: "/iCloud Drive/Wedding"
        )?.tier == .words)
        #expect(SearchMatcher.match(query: "budegt", title: "budget.xlsx")?.tier == .fuzzy)
        #expect(SearchMatcher.match(query: "hello", title: "Hide All Apps Except Frontmost") == nil)
        #expect(SearchMatcher.match(query: "zz", title: "fuzz-test.swift") == nil)
    }

    @Test func unicodeHighlightsReferToOriginalText() {
        let text = "👋 Café résumé.pdf"
        let match = SearchMatcher.match(query: "cafe resume", title: text)
        #expect(match?.tier == .words)
        #expect(match?.highlights.map { (text as NSString).substring(with: $0) } == ["Café", "résumé"])
    }

    @Test func aliasesAreExactAndScopesAreExplicit() {
        let app = LauncherResult.app(
            name: "Sublime Merge",
            url: URL(fileURLWithPath: "/Applications/Sublime Merge.app")
        )
        #expect(LauncherRanking.match(for: app, query: "sm", aliases: ["sm": "Sublime Merge"]).tier == .exact)
        #expect(LauncherScope.apps.includes(app))
        #expect(!LauncherScope.files.includes(app))
    }
}
