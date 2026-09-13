import Foundation
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

struct StubProvider: LauncherProvider {
    let rows: [LauncherResult]
    func results(for _: String) async -> [LauncherResult] {
        self.rows
    }
}

/// Shared setup for the `LauncherCommitRouting*Tests` suites (split out of
/// what used to be one large `LauncherCommitRoutingTests` file, by routed
/// result kind, purely to keep each file/type under SwiftLint's length
/// limits).
@MainActor
enum LauncherCommitRoutingFixtures {
    static func makeViewModel(rows: [LauncherResult]) async -> LauncherViewModel {
        let viewModel = LauncherViewModel(
            instantProviders: [StubProvider(rows: rows)],
            secondaryProviders: []
        )
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        await viewModel.settle()
        if let id = rows.first?.id, let index = viewModel.results.firstIndex(where: { $0.id == id }) {
            viewModel.select(at: index)
        }
        return viewModel
    }

    static func freshViewModel() -> LauncherViewModel {
        Defaults[.launcherSearchHistory] = []
        return LauncherViewModel(instantProviders: [], secondaryProviders: [])
    }

    static let track = NowPlayingTrack(
        title: "Imagine", artist: "John Lennon", trackID: "spotify:track:abc123", state: .playing
    )
}
