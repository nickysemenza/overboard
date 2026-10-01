import OverboardCore

public extension LauncherViewModel {
    var browserHandoff: ClipboardBrowserHandoff {
        let selectedID: String? = if case let .clip(item) = self.selectedResult {
            item.id
        } else {
            nil
        }
        return ClipboardBrowserHandoff(query: self.query, selectedItemID: selectedID, filter: self.clipboardFilter)
    }

    func restoreBrowserSelection(itemID: String?) {
        guard let itemID,
              let index = self.results.firstIndex(where: { result in
                  if case let .clip(item) = result {
                      return item.id == itemID
                  }
                  return false
              }) else { return }
        self.select(at: index)
    }
}
