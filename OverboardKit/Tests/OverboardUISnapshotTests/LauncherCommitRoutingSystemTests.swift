import Foundation
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

/// Pure logic, no snapshots — runs on CI too. Routing for Stream A's
/// system-action, audio-output, shell-command, and quicklink rows. Split out
/// of `LauncherCommitRoutingTests` by routed result kind, same shape as
/// `LauncherCommitRoutingHistoryTests`.
@Suite(.serialized)
@MainActor
struct LauncherCommitRoutingSystemTests {
    @Test func systemActionRowRoutesToRunSystemAction() async {
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.systemAction(.lockScreen)])

        var ran: [SystemAction] = []
        viewModel.onRunSystemAction = { ran.append($0) }

        viewModel.commit()

        #expect(ran == [.lockScreen])
    }

    @Test func audioOutputRowRoutesToSwitchAudioOutput() async {
        let device = AudioOutputDevice(id: 1, name: "AirPods Pro", isDefault: false)
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.audioOutput(device)])

        var switched: [AudioOutputDevice] = []
        viewModel.onSwitchAudioOutput = { switched.append($0) }

        viewModel.commit()

        #expect(switched == [device])
    }

    @Test func shellCommandRowRoutesToRunShellCommand() async {
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.shellCommand("brew upgrade")])

        var ran: [String] = []
        viewModel.onRunShellCommand = { ran.append($0) }

        viewModel.commit()

        #expect(ran == ["brew upgrade"])
    }

    /// Quicklinks need no dedicated closure — ↩ opens the already-resolved URL
    /// through the same callback a web-search row uses.
    @Test func quicklinkRowRoutesToOpenWebSearch() async throws {
        let link = Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}")
        let url = try #require(URL(string: "https://github.com/search?q=swift"))
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(
            rows: [.quicklink(link, query: "swift", url: url)]
        )

        var opened: [URL] = []
        viewModel.onOpenWebSearch = { opened.append($0) }

        viewModel.commit()

        #expect(opened == [url])
    }
}
