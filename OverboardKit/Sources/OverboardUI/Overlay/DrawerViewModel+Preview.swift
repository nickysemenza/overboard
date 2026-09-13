import OverboardCore

// MARK: - Preview / edit

public extension DrawerViewModel {
    var selectedItem: ClipItem? {
        self.mode == .history && self.items.indices.contains(self.selectedIndex)
            ? self.items[self.selectedIndex] : nil
    }

    func togglePreview() {
        switch self.previewState {
        case .hidden:
            guard self.selectedItem != nil else { return }
            self.previewState = .viewing
            self.onPreviewVisibilityChanged(true)
        case .viewing, .editing:
            self.closePreview()
        }
    }

    func closePreview() {
        guard self.previewState != .hidden else { return }
        self.previewState = .hidden
        self.onPreviewVisibilityChanged(false)
    }

    func beginEdit() {
        guard let item = self.selectedItem,
              item.kind == .text || item.kind == .link
        else { return }
        let wasHidden = self.previewState == .hidden
        Task {
            self.editText = await (try? self.store.plainText(for: item.id))
                ?? item.previewText ?? ""
            self.previewState = .editing
            if wasHidden {
                self.onPreviewVisibilityChanged(true)
            }
        }
    }

    func commitEdit() {
        guard self.previewState == .editing else { return }
        let text = self.editText
        self.closePreview()
        self.onCommitEditedText(text)
    }
}
