import OverboardCore
import SwiftUI

/// ⌘K command palette: fuzzy-filtered actions for the current selection,
/// floating over the card strip.
struct ActionPalette: View {
    @Bindable var viewModel: DrawerViewModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Type an action…", text: self.$viewModel.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused(self.$queryFocused)
            }
            .padding(12)

            Divider()

            if self.viewModel.filteredPaletteActions.isEmpty {
                Text("No matching actions for this selection")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(14)
            } else {
                VStack(spacing: 2) {
                    ForEach(
                        Array(self.viewModel.filteredPaletteActions.enumerated()),
                        id: \.element.id
                    ) { index, action in
                        self.row(action, isHighlighted: index == self.viewModel.paletteIndex)
                            .onTapGesture {
                                self.viewModel.runPaletteAction(at: index)
                            }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .onAppear { self.queryFocused = true }
        .onChange(of: self.viewModel.paletteQuery) {
            self.viewModel.paletteIndex = 0
        }
    }

    private func row(_ action: ClipAction, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: action.systemImage)
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
            Text(action.label)
            Spacer()
            if isHighlighted {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
    }
}
