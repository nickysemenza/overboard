import Foundation
@testable import OverboardCore
import Testing

struct LauncherSectionTests {
    private static let app = LauncherResult.app(
        name: "Notes", url: URL(fileURLWithPath: "/Applications/Notes.app")
    )
    private static let otherApp = LauncherResult.app(
        name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")
    )
    private static let file = LauncherResult.file(
        name: "notes.md", url: URL(fileURLWithPath: "/tmp/notes.md")
    )
    private static let snippet = LauncherResult.snippet(Snippet(title: "Standup", body: "notes"))
    private static let calculation = LauncherResult.calculation(input: "2+2", display: "4")
    private static let webSearch = LauncherResult.webSearch(
        query: "zzz", url: URL(fileURLWithPath: "/dev/null")
    )
    private static let nowPlaying = LauncherResult.nowPlaying(
        NowPlayingTrack(title: "Imagine", artist: "John Lennon", trackID: "spotify:track:abc", state: .playing)
    )

    @Test func sectionTitles() {
        #expect(LauncherSection.commands.title == "Commands")
        #expect(LauncherSection.apps.title == "Apps")
        #expect(LauncherSection.snippets.title == "Snippets")
        #expect(LauncherSection.clipboard.title == "Clipboard")
        #expect(LauncherSection.files.title == "Files")
        #expect(LauncherSection.settings.title == "System Settings")
        #expect(LauncherSection.recent.title == "Recent")
    }

    @Test func neverHeaderedKindsHaveNoSection() {
        #expect(LauncherSection.section(for: Self.calculation) == nil)
        #expect(LauncherSection.section(for: Self.webSearch) == nil)
        #expect(LauncherSection.section(for: Self.nowPlaying) == nil)
        #expect(LauncherSection.section(for: .askAI(prompt: "make this concise")) == nil)
    }

    @Test func recentSearchMapsToRecentSection() {
        #expect(LauncherSection.section(for: .recentSearch(query: "foo")) == .recent)
        let annotated = LauncherSection.annotate([
            .recentSearch(query: "foo"), .recentSearch(query: "bar"), Self.nowPlaying,
        ])
        #expect(annotated.map(\.header) == ["Recent", nil, nil])
    }

    /// A realistic merged list: each provider's contiguous run gets one header
    /// on its first row; never-headered kinds interleave without labels.
    @Test func mixedListAnnotation() throws {
        let url = try #require(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"))
        let results: [LauncherResult] = [
            .command(.version),
            Self.calculation,
            Self.app, Self.otherApp,
            Self.snippet,
            .systemSetting(name: "Displays", url: url),
            Self.file,
            Self.webSearch,
        ]

        let annotated = LauncherSection.annotate(results)

        // Row order (and thus the flat selection index) is untouched.
        #expect(annotated.map(\.result) == results)
        #expect(annotated.map(\.header) == [
            "Commands", nil, "Apps", nil, "Snippets", "System Settings", "Files", nil,
        ])
    }

    /// Runs are consecutive only — a section that reappears after a break
    /// starts a fresh run with its own header. No re-sorting.
    @Test func consecutiveRunsGetSeparateHeaders() {
        let annotated = LauncherSection.annotate([Self.app, Self.file, Self.otherApp])
        #expect(annotated.map(\.header) == ["Apps", "Files", "Apps"])
    }

    @Test func nilSectionRunBreaksAdjacentRuns() {
        // The calculator row splits the app run; the second half is a new run.
        let annotated = LauncherSection.annotate([Self.app, Self.calculation, Self.otherApp])
        #expect(annotated.map(\.header) == ["Apps", nil, "Apps"])
    }

    @Test func emptyListAnnotatesToEmpty() {
        #expect(LauncherSection.annotate([]).isEmpty)
    }
}
