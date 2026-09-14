import Foundation
@testable import OverboardCore
import Testing

/// The action matrices per result kind, the running-app variant, and the
/// positional hint mapping. These are the single source of truth the footer and
/// palette read, so lock them down.
@MainActor
struct LauncherActionsTests {
    private func clip(kind: ItemKind, preview: String = "hello") -> ClipItem {
        ClipItem(
            contentHash: UUID().uuidString, kind: kind, previewText: preview,
            sourceBundleID: nil, sourceAppName: nil, byteSize: 1,
            createdAt: Date(), lastUsedAt: Date(), updatedAt: Date()
        )
    }

    private func appURL() -> URL {
        URL(fileURLWithPath: "/Applications/Notes.app")
    }

    // MARK: Per-kind matrices

    @Test func appNotRunning() {
        let result = LauncherResult.app(name: "Notes", url: self.appURL())
        #expect(LauncherActions.actions(for: result) == [.open, .revealInFinder, .copyPath])
    }

    @Test func appRunningSwitchesAndOffersQuit() {
        let result = LauncherResult.app(name: "Notes", url: self.appURL())
        let context = LauncherActionContext(isAppRunning: true)
        #expect(
            LauncherActions.actions(for: result, context: context)
                == [.switchTo, .revealInFinder, .copyPath, .quitApp]
        )
    }

    @Test func textClip() {
        let result = LauncherResult.clip(self.clip(kind: .text))
        #expect(LauncherActions.actions(for: result) == [.paste, .copy, .pastePlain, .preview, .pin])
    }

    @Test func linkClipAddsOpenLink() {
        let result = LauncherResult.clip(self.clip(kind: .link, preview: "https://example.com"))
        #expect(LauncherActions.actions(for: result) == [.paste, .copy, .pastePlain, .openLink, .preview, .pin])
    }

    @Test func snippet() {
        let result = LauncherResult.snippet(Snippet(title: "Standup", body: "notes"))
        #expect(LauncherActions.actions(for: result) == [.paste, .copy])
    }

    @Test func file() {
        let result = LauncherResult.file(name: "doc.txt", url: URL(fileURLWithPath: "/tmp/doc.txt"))
        #expect(LauncherActions.actions(for: result) == [.open, .revealInFinder, .copyPath, .preview])
    }

    @Test func calculation() {
        let result = LauncherResult.calculation(input: "1+1", display: "2")
        #expect(LauncherActions.actions(for: result) == [.copy, .paste])
    }

    @Test func webSearch() throws {
        let url = try #require(URL(string: "https://google.com/search?q=x"))
        let result = LauncherResult.webSearch(query: "x", url: url)
        #expect(LauncherActions.actions(for: result) == [.search])
    }

    @Test func systemSetting() throws {
        let url = try #require(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"))
        let result = LauncherResult.systemSetting(name: "Displays", url: url)
        #expect(LauncherActions.actions(for: result) == [.openSetting])
    }

    @Test func command() {
        let result = LauncherResult.command(.version)
        #expect(LauncherActions.actions(for: result) == [.runCommand])
    }

    @Test func recentSearch() {
        let result = LauncherResult.recentSearch(query: "old")
        #expect(LauncherActions.actions(for: result) == [.rerunSearch, .removeRecent])
    }

    @Test func nowPlaying() {
        let track = NowPlayingTrack(title: "Imagine", artist: "Lennon", trackID: "id", state: .playing)
        let result = LauncherResult.nowPlaying(track)
        #expect(LauncherActions.actions(for: result) == [.copyLink, .openInSpotify])
    }

    @Test func askAI() {
        let result = LauncherResult.askAI(prompt: "make this concise")
        #expect(LauncherActions.actions(for: result) == [.paste, .copy])
    }

    @Test func systemAction() {
        let result = LauncherResult.systemAction(.lockScreen)
        #expect(LauncherActions.actions(for: result) == [.runCommand])
    }

    @Test func audioOutput() {
        let result = LauncherResult.audioOutput(AudioOutputDevice(id: 1, name: "AirPods Pro", isDefault: false))
        #expect(LauncherActions.actions(for: result) == [.switchTo])
    }

    @Test func quicklink() throws {
        let link = Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}")
        let url = try #require(URL(string: "https://github.com/search?q=swift"))
        let result = LauncherResult.quicklink(link, query: "swift", url: url)
        #expect(LauncherActions.actions(for: result) == [.openLink])
    }

    @Test func shellCommand() {
        let result = LauncherResult.shellCommand("brew upgrade")
        #expect(LauncherActions.actions(for: result) == [.runCommand])
    }

    private func calendarEvent(url: URL? = nil) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: "evt1",
            title: "Standup",
            start: Date(),
            end: Date().addingTimeInterval(1800),
            url: url
        )
    }

    @Test func calendarEventWithMeetingLink() throws {
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let result = LauncherResult.calendarEvent(self.calendarEvent(url: url))
        #expect(LauncherActions.actions(for: result) == [.joinMeeting, .copyLink, .openInCalendar])
    }

    @Test func calendarEventWithoutMeetingLink() {
        let result = LauncherResult.calendarEvent(self.calendarEvent())
        #expect(LauncherActions.actions(for: result) == [.openInCalendar])
    }

    // MARK: Positional hint mapping

    @Test func hintMapsFirstThreePositions() {
        #expect(LauncherActions.hint(at: 0) == "↩")
        #expect(LauncherActions.hint(at: 1) == "⌘↩")
        #expect(LauncherActions.hint(at: 2) == "⌥↩")
        #expect(LauncherActions.hint(at: 3) == nil)
        #expect(LauncherActions.hint(at: 99) == nil)
    }
}
