import OverboardCore
import SwiftUI

public struct DrawerView: View {
    @Bindable var viewModel: DrawerViewModel
    @FocusState private var searchFocused: Bool

    public init(viewModel: DrawerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 10) {
            self.searchBar
            self.cardStrip
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(12)
        .onAppear { self.searchFocused = true }
        .onChange(of: self.viewModel.query) {
            self.viewModel.scheduleSearch()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your clipboard…", text: self.$viewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(self.$searchFocused)
            if !self.viewModel.items.isEmpty {
                Text("\(self.viewModel.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
    }

    private var cardStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(self.viewModel.items.enumerated()), id: \.element.id) { index, item in
                        ItemCardView(
                            item: item,
                            index: index,
                            isSelected: index == self.viewModel.selectedIndex,
                            store: self.viewModel.storeForCards
                        )
                        .onTapGesture {
                            self.viewModel.select(at: index)
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
            }
            .onChange(of: self.viewModel.selectedIndex) {
                guard self.viewModel.items.indices.contains(self.viewModel.selectedIndex) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(self.viewModel.items[self.viewModel.selectedIndex].id, anchor: .center)
                }
            }
        }
        .frame(height: 184)
        .overlay {
            if self.viewModel.items.isEmpty {
                ContentUnavailableView {
                    Label(
                        self.viewModel.query.isEmpty ? "Nothing captured yet" : "No matches",
                        systemImage: "sailboat"
                    )
                } description: {
                    Text(self.viewModel.query.isEmpty
                        ? "Copy something and it'll wash up here."
                        : "Try a different search.")
                }
            }
        }
    }
}
