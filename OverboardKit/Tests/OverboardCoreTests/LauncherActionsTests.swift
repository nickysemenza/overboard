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
        #expect(LauncherActions.actions(for: result) == [.paste, .copy, .pastePlain])
    }

    @Test func linkClipAddsOpenLink() {
        let result = LauncherResult.clip(self.clip(kind: .link, preview: "https://example.com"))
        #expect(LauncherActions.actions(for: result) == [.paste, .copy, .pastePlain, .openLink])
    }

    @Test func snippet() {
        let result = LauncherResult.snippet(Snippet(title: "Standup", body: "notes"))
        #expect(LauncherActions.actions(for: result) == [.paste, .copy])
    }

    @Test func file() {
        let result = LauncherResult.file(name: "doc.txt", url: URL(fileURLWithPath: "/tmp/doc.txt"))
        #expect(LauncherActions.actions(for: result) == [.open, .revealInFinder, .copyPath])
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

    // MARK: Positional hint mapping

    @Test func hintMapsFirstThreePositions() {
        #expect(LauncherActions.hint(at: 0) == "↩")
        #expect(LauncherActions.hint(at: 1) == "⌘↩")
        #expect(LauncherActions.hint(at: 2) == "⌥↩")
        #expect(LauncherActions.hint(at: 3) == nil)
        #expect(LauncherActions.hint(at: 99) == nil)
    }
}
