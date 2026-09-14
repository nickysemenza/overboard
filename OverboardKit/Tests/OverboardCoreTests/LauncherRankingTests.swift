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

    @Test func sameQueryLearningOutranksTier() {
        // A same-query pick is promoted above its natural tier: Sublime
        // Merge only matches "sm" via a full acronym (`.prefix` after
        // change #1), which naturally loses to a file whose stem literally
        // is "sm" (`.exact`) — but a recorded selection reverses that.
        let app = LauncherResult.app(
            name: "Sublime Merge",
            url: URL(fileURLWithPath: "/Applications/Sublime Merge.app")
        )
        let file = LauncherResult.file(name: "sm.png", url: URL(fileURLWithPath: "/tmp/sm.png"))
        #expect(LauncherRanking.sorted([file, app], query: "sm", usage: [app.id: 1]).first == app)

        // Still below the fixed, always-first kinds.
        let shell = LauncherResult.shellCommand("echo sm")
        #expect(LauncherRanking.sorted([shell, app], query: "sm", usage: [app.id: 100]).first == shell)

        // Two rows promoted into the same slot with equal usage fall back to
        // natural tier: "sm.png" is `.exact`, "smart" only `.prefix`.
        let smart = LauncherResult.file(name: "smart", url: URL(fileURLWithPath: "/tmp/smart"))
        #expect(
            LauncherRanking.sorted([smart, file], query: "sm", usage: [smart.id: 1, file.id: 1]).first == file
        )

        // Within-tier usage tiebreak (both stems equal "hello", so both
        // `.exact`) still holds.
        let exact = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        let peer = LauncherResult.file(name: "hello.md", url: URL(fileURLWithPath: "/tmp/hello.md"))
        #expect(LauncherRanking.sorted([exact, peer], query: "hello", usage: [peer.id: 2]).first == peer)
    }

    @Test func acronymBeatsPrefixFilesRegardlessOfOrder() {
        let app = LauncherResult.app(
            name: "Sublime Merge",
            url: URL(fileURLWithPath: "/Applications/Sublime Merge.app")
        )
        let smart = LauncherResult.file(name: "smart", url: URL(fileURLWithPath: "/tmp/smart"))
        let smime = LauncherResult.file(name: "smime", url: URL(fileURLWithPath: "/tmp/smime"))
        #expect(LauncherRanking.sorted([smart, smime, app], query: "sm").first == app)
        #expect(LauncherRanking.sorted([app, smart, smime], query: "sm").first == app)
    }

    @Test func directoryWordFilesRankBelowAcronymApp() {
        let app = LauncherResult.app(
            name: "Sublime Merge",
            url: URL(fileURLWithPath: "/Applications/Sublime Merge.app")
        )
        let file = LauncherResult.file(name: "notes.txt", url: URL(fileURLWithPath: "/x/smoke/notes.txt"))
        #expect(LauncherRanking.sorted([file, app], query: "sm").first == app)
    }

    @Test func exactStemFileStillBeatsUnlearnedAcronym() {
        // Documents the trade-off: without a recorded selection, a file
        // whose stem literally is the query still beats an acronym match.
        let app = LauncherResult.app(
            name: "Sublime Merge",
            url: URL(fileURLWithPath: "/Applications/Sublime Merge.app")
        )
        let file = LauncherResult.file(name: "sm.png", url: URL(fileURLWithPath: "/tmp/sm.png"))
        #expect(LauncherRanking.sorted([app, file], query: "sm").first == file)
    }

    @Test func aliasBeatsExactFile() {
        let app = LauncherResult.app(
            name: "Sublime Merge",
            url: URL(fileURLWithPath: "/Applications/Sublime Merge.app")
        )
        let file = LauncherResult.file(name: "sm.png", url: URL(fileURLWithPath: "/tmp/sm.png"))
        // Both land at `.exact` (alias vs. stem match) — the app-before-file
        // kind tiebreak (change #2) decides it.
        #expect(LauncherRanking.sorted([file, app], query: "sm", aliases: ["sm": "Sublime Merge"]).first == app)
    }

    @Test func partialInitialsStayWordsTier() {
        let app = LauncherResult.app(
            name: "Visual Studio Code", url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        )
        #expect(LauncherRanking.match(for: app, query: "vs").tier == .words)
        // A single letter is never treated as an acronym (see
        // `singleWordNamesDoNotInitialMatch`), so it can't reach `.prefix`.
        #expect(AppMatcher.score(query: "s", name: "Visual Studio Code") != .initials)
    }

    @Test func acronymTiesWithNamePrefixApps() {
        let stickies = LauncherResult.app(name: "Stickies", url: URL(fileURLWithPath: "/Applications/Stickies.app"))
        let sublimeText = LauncherResult.app(
            name: "Sublime Text", url: URL(fileURLWithPath: "/Applications/Sublime Text.app")
        )
        // Both are `.prefix` for "st" (name-prefix vs. full acronym); with no
        // usage or frecency difference, provider order (name-prefix apps
        // first) decides — asserted here via the input order.
        #expect(LauncherRanking.sorted([stickies, sublimeText], query: "st").first == stickies)
    }

    @Test func frecencyBreaksTiesWithinTier() {
        let stickies = LauncherResult.app(name: "Stickies", url: URL(fileURLWithPath: "/Applications/Stickies.app"))
        let sublimeText = LauncherResult.app(
            name: "Sublime Text", url: URL(fileURLWithPath: "/Applications/Sublime Text.app")
        )
        #expect(
            LauncherRanking.sorted([stickies, sublimeText], query: "st", frecency: [sublimeText.id: 5]).first
                == sublimeText
        )

        // Frecency cannot lift a `.words` row over a `.prefix` row: partial
        // initials only ("stt" for "Simple Task Tracker") stays `.words`.
        let wordsApp = LauncherResult.app(
            name: "Simple Task Tracker", url: URL(fileURLWithPath: "/Applications/Simple Task Tracker.app")
        )
        #expect(
            LauncherRanking.sorted([wordsApp, stickies], query: "st", frecency: [wordsApp.id: 100]).first == stickies
        )
    }

    @Test func systemSettingAcronymIsPrefixTier() throws {
        let setting = try LauncherResult.systemSetting(
            name: "Keyboard Shortcuts",
            url: #require(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
        )
        #expect(LauncherRanking.match(for: setting, query: "ks").tier == .prefix)
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

    @Test func quicklinkAndShellCommandSortFirst() {
        let link = Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}")
        let quicklink = LauncherResult.quicklink(link, query: "", url: URL(fileURLWithPath: "/dev/null"))
        let shell = LauncherResult.shellCommand("brew upgrade")
        let app = LauncherResult.app(name: "GitHub Desktop", url: URL(fileURLWithPath: "/Applications/GitHub.app"))
        let sorted = LauncherRanking.sorted([app, quicklink, shell], query: "gh")
        #expect(sorted.prefix(2).contains(quicklink))
        #expect(sorted.prefix(2).contains(shell))
        #expect(sorted.last == app)
    }

    @Test func audioOutputKeywordHitsWordsTier() {
        let device = AudioOutputDevice(id: 1, name: "AirPods Pro", isDefault: false)
        let result = LauncherResult.audioOutput(device)
        #expect(LauncherRanking.match(for: result, query: "audio").tier == .words)
    }

    @Test func calendarEventSortsBeforeNowPlaying() {
        let event = CalendarEvent(
            eventIdentifier: "evt1", title: "Standup", start: Date(), end: Date().addingTimeInterval(1800)
        )
        let calendar = LauncherResult.calendarEvent(event)
        let nowPlaying = LauncherResult.nowPlaying(
            NowPlayingTrack(title: "Imagine", artist: "John Lennon", trackID: "spotify:track:abc", state: .playing)
        )
        #expect(LauncherRanking.sorted([nowPlaying, calendar], query: "zzz") == [calendar, nowPlaying])
    }
}
