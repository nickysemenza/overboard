import AppKit
import OverboardCore
import SwiftUI

public struct LauncherView: View {
    @Bindable var viewModel: LauncherViewModel
    @FocusState private var fieldFocused: Bool

    public init(viewModel: LauncherViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            self.searchBar
            if !self.viewModel.results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(self.viewModel.results.enumerated()), id: \.element.id) { index, result in
                        LauncherRow(result: result, isSelected: index == self.viewModel.selectedIndex)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture {
                                self.viewModel.selectedIndex = index
                                self.viewModel.commit()
                            }
                    }
                }
            }
        }
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(12)
        .onAppear {
            self.fieldFocused = true
        }
        .onChange(of: self.viewModel.showGeneration) {
            self.fieldFocused = true
        }
        .onChange(of: self.viewModel.query) {
            self.viewModel.scheduleSearch()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.secondary)
            TextField("Calculate, find files, search the web…", text: self.$viewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(self.$fieldFocused)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }
}

struct LauncherRow: View {
    let result: LauncherResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            self.icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.title)
                    .font(.body.weight(self.titleWeight))
                    .lineLimit(1)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if self.isSelected {
                Text(self.shortcutHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            self.isSelected ? Color.accentColor.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    @ViewBuilder private var icon: some View {
        switch self.result {
        case .calculation:
            Image(systemName: "equal.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case let .file(_, url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .webSearch:
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
        }
    }

    private var title: String {
        switch self.result {
        case let .calculation(_, display): display
        case let .file(name, _): name
        case let .webSearch(query, _): "Search Google for “\(query)”"
        }
    }

    private var titleWeight: Font.Weight {
        if case .calculation = self.result { .semibold } else { .regular }
    }

    private var subtitle: String {
        switch self.result {
        case let .calculation(input, _): "\(input.trimmingCharacters(in: .whitespaces)) ="
        case let .file(_, url): (url.path as NSString).abbreviatingWithTildeInPath
        case .webSearch: "Open in browser"
        }
    }

    private var shortcutHint: String {
        switch self.result {
        case .calculation: "↩ copy   ⌘↩ paste"
        case .file: "↩ open   ⌘↩ reveal   ⌥↩ copy path"
        case .webSearch: "↩ search"
        }
    }
}
