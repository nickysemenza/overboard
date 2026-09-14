import Foundation
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

/// Tab / ⇧Tab scope cycling. Split out of `LauncherScopeTests` purely to
/// keep that struct under SwiftLint's `type_body_length` limit (the same
/// reason the `LauncherCommitRouting*Tests` suites are split by result
/// kind) — these are otherwise just more scope-bar tests.
@Suite(.serialized)
@MainActor
struct LauncherScopeCycleTests {
    /// Cycling forward through all four scopes and once more lands back on
    /// the first — the wrap, not just the step.
    @Test func cycleScopeAdvancesAndWraps() {
        let model = LauncherViewModel(secondaryProviders: [])
        for expected: LauncherScope in [.files, .clipboard, .apps, .all] {
            model.cycleScope(1)
            #expect(model.scope == expected)
        }
    }

    @Test func cycleScopeBackwardWraps() {
        let model = LauncherViewModel(secondaryProviders: [])
        for expected: LauncherScope in [.apps, .clipboard, .files, .all] {
            model.cycleScope(-1)
            #expect(model.scope == expected)
        }
    }

    /// Cycling scope goes through `setScope`, so it inherits the same side
    /// effects a scope-bar click has: the preview closes and the result
    /// list is rescheduled against the new scope.
    @Test func cycleScopeClosesPreviewAndReschedules() async {
        let file = LauncherResult.file(name: "notes.txt", url: URL(fileURLWithPath: "/tmp/notes.txt"))
        let app = LauncherResult.app(name: "Notes", url: URL(fileURLWithPath: "/Applications/Notes.app"))
        let model = LauncherViewModel(instantProviders: [StubProvider(rows: [app, file])], secondaryProviders: [])
        model.query = "notes"
        model.scheduleSearch()
        await model.settle()
        model.togglePreview()
        #expect(model.isPreviewVisible)
        model.cycleScope(1)
        #expect(model.scope == .files && !model.isPreviewVisible)
        await model.settle()
        #expect(model.results == [file])
    }
}
