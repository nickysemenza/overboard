import AppKit
import SwiftUI

struct NativePaletteQueryField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: self.$text)
    }

    func makeNSView(context: Context) -> MountedField {
        let field = MountedField()
        field.stringValue = self.text
        field.placeholderString = "Type an action…"
        field.setAccessibilityLabel("Filter actions")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .title3)
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: MountedField, context: Context) {
        context.coordinator.text = self.$text
        if field.stringValue != self.text {
            field.stringValue = self.text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            self.text.wrappedValue = field.stringValue
        }
    }

    final class MountedField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard self.window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, !self.isHiddenOrHasHiddenAncestor else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
