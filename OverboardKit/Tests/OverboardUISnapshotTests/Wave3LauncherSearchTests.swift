import Foundation
import OverboardCore
@testable import OverboardUI
import Testing

@MainActor
struct Wave3LauncherSearchTests {
    @Test func clipboardDefaultDoesNotForcePreview() {
        let model = LauncherViewModel(secondaryProviders: [], defaultClipboard: true)
        #expect(model.scope == .clipboard)
        #expect(!model.showsPreview)
        model.isPreviewVisible = true
        #expect(model.showsPreview)
    }

    @Test func hiddenInstantSearchCannotPublishOrRestart() async {
        let gate = Wave3ProviderGate()
        let model = LauncherViewModel(instantProviders: [Wave3GatedProvider(gate: gate)], secondaryProviders: [])
        model.query = "old"
        model.scheduleSearch()
        await gate.waitForRequest()
        let task = model.searchTask
        model.stopObserving()
        let hidden = model.results
        await gate.release()
        await task?.value
        model.scheduleSearch()
        #expect(model.results == hidden)
        #expect(!model.isSearching)
    }

    @Test func hiddenSecondarySearchCannotPublish() async {
        let gate = Wave3ProviderGate()
        let model = LauncherViewModel(
            secondaryProviders: [Wave3GatedProvider(gate: gate)],
            secondaryDebounceInterval: .zero
        )
        model.query = "old"
        model.scheduleSearch()
        await gate.waitForRequest()
        let task = model.secondaryTask
        model.stopObserving()
        let hidden = model.results
        await gate.release()
        await task?.value
        #expect(model.results == hidden)
        #expect(!model.isSearching)
    }

    @Test func newerQueryDoesNotWaitForCancellationInsensitiveSecondary() async {
        let gate = Wave3ProviderGate()
        let model = LauncherViewModel(
            secondaryProviders: [Wave3GatedProvider(gate: gate)],
            secondaryDebounceInterval: .zero
        )
        model.query = "old"
        model.scheduleSearch()
        await gate.waitForRequest()
        let task = model.secondaryTask
        model.query = "new"
        model.scheduleSearch()
        await model.settle()
        #expect(model.results.first?.id == "file:/fixture/new.txt")
        await gate.release()
        await task?.value
        #expect(model.results.first?.id == "file:/fixture/new.txt")
    }

    @Test func manuallySelectedIdentitySurvivesAsyncReordering() async {
        let gate = Wave3ProviderGate()
        let model = LauncherViewModel(
            secondaryProviders: [Wave3GatedProvider(gate: gate)],
            secondaryDebounceInterval: .zero
        )
        model.query = "old"
        model.scheduleSearch()
        await gate.waitForRequest()
        model.select(at: 0)
        let chosen = model.selectedResult?.id
        await gate.release()
        await model.settle()
        #expect(model.results.first?.id == "file:/fixture/old.txt")
        #expect(model.selectedResult?.id == chosen)
    }
}

private struct Wave3GatedProvider: LauncherProvider {
    let gate: Wave3ProviderGate

    func results(for query: String) async -> [LauncherResult] {
        if query == "old" {
            await self.gate.request()
        }
        return [.file(name: query + ".txt", url: URL(fileURLWithPath: "/fixture/" + query + ".txt"))]
    }
}

private actor Wave3ProviderGate {
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func request() async {
        await withCheckedContinuation { continuation in
            self.requestContinuation = continuation
            self.observer?.resume()
            self.observer = nil
        }
    }

    func waitForRequest() async {
        guard self.requestContinuation == nil else { return }
        await withCheckedContinuation { self.observer = $0 }
    }

    func release() {
        self.requestContinuation?.resume()
        self.requestContinuation = nil
    }
}
