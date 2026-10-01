import AppKit
import OverboardCore

public enum PanelActionID: String, Sendable, CaseIterable {
    case paste, copy, plainPaste, stack, preview

    public var metadata: PanelActionMetadata {
        switch self {
        case .paste: .init(id: self, label: "Paste", systemImage: "doc.on.clipboard", shortcut: "↩")
        case .copy: .init(id: self, label: "Copy", systemImage: "doc.on.doc", shortcut: "⌘↩")
        case .plainPaste: .init(id: self, label: "Paste as Plain Text", systemImage: "textformat", shortcut: "⇧↩")
        case .stack: .init(id: self, label: "Add to Stack", systemImage: "square.stack.3d.up", shortcut: "⌘⇧↩")
        case .preview: .init(id: self, label: "Preview", systemImage: "eye", shortcut: "⌘Y")
        }
    }

    static func commit(for modifiers: NSEvent.ModifierFlags) -> Self? {
        switch NativePanelKeyRouting.modifiers(modifiers) {
        case []: .paste
        case .command: .copy
        case .shift: .plainPaste
        case [.command, .shift]: .stack
        default: nil
        }
    }
}

public struct PanelActionMetadata: Sendable, Equatable {
    public let id: PanelActionID
    public let label: String
    public let systemImage: String
    public let shortcut: String
}

extension LauncherAction {
    var panelActionID: PanelActionID? {
        switch self {
        case .paste: .paste
        case .copy: .copy
        case .pastePlain: .plainPaste
        case .preview: .preview
        default: nil
        }
    }
}
