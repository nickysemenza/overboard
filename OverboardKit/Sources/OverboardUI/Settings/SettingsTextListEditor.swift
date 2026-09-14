import SwiftUI

/// A monospaced multi-line text editor for the newline-delimited list
/// preferences (aliases, quicklinks, transform rules, folders, …). Every
/// settings tab that edits one of these lists used to copy-paste the same
/// font/height/background around a bare `TextEditor`; this is that one
/// shared shape.
struct SettingsTextListEditor: View {
    @Binding var text: String
    var height: CGFloat
    var accessibilityLabel: String

    var body: some View {
        TextEditor(text: self.$text)
            .font(.body.monospaced())
            .frame(height: self.height)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(self.accessibilityLabel)
    }
}
