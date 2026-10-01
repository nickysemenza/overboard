import OverboardCore

enum LauncherPaletteEntry: Identifiable, Equatable {
    case action(LauncherAction), stack, copyCalculation, clipQuicklink(Quicklink)

    var id: String {
        switch self {
        case let .action(action): action.panelActionID?.rawValue ?? action.id
        case .stack: PanelActionID.stack.rawValue
        case .copyCalculation: "copyCalculation"
        case let .clipQuicklink(quicklink): "clipboardQuicklink:\(quicklink.keyword)"
        }
    }

    var label: String {
        switch self {
        case let .action(action): action.panelActionID?.metadata.label ?? action.label
        case .stack: PanelActionID.stack.metadata.label
        case .copyCalculation: "Copy Calculation"
        case let .clipQuicklink(quicklink): SelectedClipQuicklinks.label(for: quicklink)
        }
    }

    var systemImage: String {
        switch self {
        case let .action(action): action.systemImage
        case .stack: PanelActionID.stack.metadata.systemImage
        case .copyCalculation: PanelActionID.copy.metadata.systemImage
        case .clipQuicklink: "link"
        }
    }

    var detail: String? {
        if case let .clipQuicklink(quicklink) = self {
            return quicklink.template
        }
        return nil
    }
}

public extension LauncherViewModel {
    func performPanelCommit(_ action: PanelActionID, onAddClipToStack: ((ClipItem) -> Void)? = nil) {
        guard !self.resultsAreStale, let result = self.selectedResult else { return }
        switch action {
        case .stack:
            if case let .clip(item) = result {
                onAddClipToStack?(item)
            }
        case .plainPaste:
            if self.selectedActions.contains(.pastePlain) {
                self.perform(.pastePlain)
            }
        case .paste:
            self.perform(self.selectedActions.contains(.paste) ? .paste : self.primaryAction ?? .open)
        case .copy:
            if let copyAction = self.selectedActions.first(where: { [.copy, .copyLink, .copyPath].contains($0) }) {
                self.perform(copyAction)
            }
        case .preview: self.togglePreview()
        }
    }

    internal func filteredPaletteEntries(
        includeStack: Bool, includeClipQuicklinks: Bool = false
    ) -> [LauncherPaletteEntry] {
        var entries = self.selectedActions.map { action -> LauncherPaletteEntry in
            if action == .copy, case .calculation = self.selectedResult {
                return .copyCalculation
            }
            return .action(action)
        }
        if includeStack, case .clip = self.selectedResult {
            entries.append(.stack)
        }
        if includeClipQuicklinks, case let .clip(item) = self.selectedResult {
            entries += SelectedClipQuicklinks.available(for: item).map(LauncherPaletteEntry.clipQuicklink)
        }
        let needle = self.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? entries : entries.filter { $0.label.lowercased().contains(needle) }
    }

    internal func runPaletteEntry(
        at index: Int? = nil, onAddClipToStack: ((ClipItem) -> Void)? = nil,
        onRunClipQuicklink: ((ClipItem, Quicklink) -> Void)? = nil
    ) {
        let entries = self.filteredPaletteEntries(
            includeStack: onAddClipToStack != nil, includeClipQuicklinks: onRunClipQuicklink != nil
        )
        let chosen = index ?? self.paletteIndex
        guard !self.resultsAreStale, entries.indices.contains(chosen) else { return }
        self.closePalette()
        switch entries[chosen] {
        case let .action(action): self.perform(action)
        case .stack: self.performPanelCommit(.stack, onAddClipToStack: onAddClipToStack)
        case .copyCalculation: self.performPanelCommit(.copy)
        case let .clipQuicklink(quicklink):
            if case let .clip(item) = self.selectedResult {
                onRunClipQuicklink?(item, quicklink)
            }
        }
    }

    internal func movePaletteEntry(_ delta: Int, includeStack: Bool, includeClipQuicklinks: Bool = false) {
        let count = self.filteredPaletteEntries(
            includeStack: includeStack, includeClipQuicklinks: includeClipQuicklinks
        ).count
        guard count > 0 else { return }
        self.paletteIndex = min(max(self.paletteIndex + delta, 0), count - 1)
    }
}
