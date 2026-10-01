import AppKit
import Observation
import OverboardCore

public extension LauncherPanelController {
    func showBrowser(state: ClipboardBrowserHandoff, target: NSRunningApplication? = nil) {
        if self.isVisible {
            self.viewModel.setScope(.clipboard)
            self.viewModel.query = state.query
            self.updateBrowserTarget(target)
        }
        self.show(scope: .clipboard, query: state.query, target: target)
        self.viewModel.clipboardFilter = state.filter
        self.viewModel.scheduleSearch()
        self.browserRequestGeneration += 1
        self.pendingBrowserState = state
        self.restorePendingBrowserSelection(generation: self.browserRequestGeneration)
    }

    func showDrawerSelection() {
        guard let onShowDrawer else { return }
        let state = self.viewModel.browserHandoff
        let target = self.targetApp
        self.hide()
        onShowDrawer(state, target)
    }

    internal func runClipQuicklink(_ item: ClipItem, quicklink: Quicklink) {
        guard let onRunClipQuicklink else { return }
        self.hide()
        onRunClipQuicklink(item, quicklink)
    }

    private func restorePendingBrowserSelection(generation: Int) {
        guard generation == self.browserRequestGeneration, let state = self.pendingBrowserState else { return }
        guard self.isVisible, self.viewModel.scope == .clipboard, self.viewModel.query == state.query,
              self.viewModel.clipboardFilter == state.filter
        else {
            self.pendingBrowserState = nil
            return
        }
        let finished = withObservationTracking {
            _ = self.viewModel.results
            _ = self.viewModel.query
            _ = self.viewModel.scope
            _ = self.viewModel.clipboardFilter
            return !self.viewModel.resultsAreStale && !self.viewModel.isSearching
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.restorePendingBrowserSelection(generation: generation)
            }
        }
        guard finished else { return }
        self.pendingBrowserState = nil
        self.viewModel.restoreBrowserSelection(itemID: state.selectedItemID)
    }
}
