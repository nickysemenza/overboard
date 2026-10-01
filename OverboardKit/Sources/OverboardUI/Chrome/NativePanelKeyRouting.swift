import AppKit
import OverboardCore

enum PanelKeyFocus: Equatable {
    case results, search(hasText: Bool), palette, editor, dialog, markedText, control
}

enum NativePanelKeyRouting {
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control])
    }

    static func focus(in window: NSWindow) -> PanelKeyFocus {
        if window.attachedSheet != nil || NSApp?.modalWindow != nil {
            return .dialog
        }
        if let editor = window.firstResponder as? NSTextView {
            if editor.hasMarkedText() {
                return .markedText
            }
            if !editor.isFieldEditor {
                return .editor
            }
            return .search(hasText: !editor.string.isEmpty)
        }
        if window.firstResponder is NSControl {
            return .control
        }
        return .results
    }

    static func shouldDefer(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, focus: PanelKeyFocus) -> Bool {
        switch focus {
        case .editor, .dialog, .markedText, .control: return true
        case .search(hasText: true) where keyCode == KeyCode.leftArrow.rawValue
            || keyCode == KeyCode.rightArrow.rawValue: return true
        default: break
        }
        switch KeyCode(rawValue: keyCode) {
        case .tab: return true
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            return !Self.modifiers(modifiers).subtracting(.shift).isEmpty
        default: return false
        }
    }
}
