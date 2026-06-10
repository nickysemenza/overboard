import Foundation
@testable import OverboardCore
import Testing

struct AppMatcherTests {
    private let apps = [
        "Sublime Merge", "Sublime Text", "Safari", "System Settings",
        "Visual Studio Code", "Spotify", "Mail",
    ]

    private func ranked(_ query: String, aliases: [String: String] = [:]) -> [String] {
        AppMatcher.rank(query: query, names: self.apps, aliases: aliases).map { self.apps[$0] }
    }

    // MARK: - Scoring

    @Test func initialsMatchWithoutConfiguration() {
        #expect(AppMatcher.score(query: "sm", name: "Sublime Merge") == .initials)
        #expect(AppMatcher.score(query: "vsc", name: "Visual Studio Code") == .initials)
        #expect(AppMatcher.score(query: "ss", name: "System Settings") == .initials)
    }

    @Test func prefixBeatsInitialsAndSubstring() {
        #expect(AppMatcher.score(query: "subl", name: "Sublime Merge") == .namePrefix)
        #expect(AppMatcher.score(query: "merge", name: "Sublime Merge") == .substring)
        #expect(AppMatcher.score(query: "xyz", name: "Sublime Merge") == nil)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(AppMatcher.score(query: "SM", name: "Sublime Merge") == .initials)
        #expect(AppMatcher.score(query: "SAFARI", name: "Safari") == .namePrefix)
    }

    @Test func singleWordNamesDoNotInitialMatch() {
        // "s" as initials of "Safari" would make every letter a match.
        #expect(AppMatcher.score(query: "s", name: "Safari") == .namePrefix)
        #expect(AppMatcher.score(query: "y", name: "Spotify") == .substring)
    }

    @Test func hyphenatedWordsCountForInitials() {
        #expect(AppMatcher.score(query: "im", name: "Intel-MacTool") == .initials)
    }

    // MARK: - Ranking

    @Test func smRanksSublimeAppsFirst() {
        let results = self.ranked("sm")
        #expect(results.first == "Sublime Merge")
        #expect(!results.contains("Safari"))
    }

    @Test func aliasOutranksEverything() {
        let results = self.ranked("sm", aliases: ["sm": "System Settings"])
        #expect(results.first == "System Settings")
        #expect(results.contains("Sublime Merge")) // still there, just below
    }

    @Test func aliasTargetMatchesByPrefix() {
        let results = self.ranked("code", aliases: ["code": "Visual Studio"])
        #expect(results.first == "Visual Studio Code")
    }

    @Test func tiesBreakByShorterName() {
        // Both Sublimes initial-match "s" prefix-style queries equally.
        let results = self.ranked("sublime")
        #expect(results == ["Sublime Text", "Sublime Merge"])
    }

    @Test func limitIsRespected() {
        let many = (0 ..< 20).map { "App \($0)" }
        #expect(AppMatcher.rank(query: "app", names: many, limit: 5).count == 5)
    }

    @Test func emptyQueryRanksNothing() {
        #expect(self.ranked("").isEmpty)
        #expect(self.ranked("   ").isEmpty)
    }

    // MARK: - Alias parsing

    @Test func parsesAliasLines() {
        let raw = """
        sm = Sublime Merge
        # comment
        code=Visual Studio Code

        broken line without separator
        CODE = Xcode
        """
        let aliases = AppMatcher.parseAliases(raw)
        #expect(aliases == ["sm": "Sublime Merge", "code": "Xcode"])
    }

    @Test func parsesEmptyAndJunkToNothing() {
        #expect(AppMatcher.parseAliases("").isEmpty)
        #expect(AppMatcher.parseAliases("= name\nalias =\n#x").isEmpty)
    }
}
