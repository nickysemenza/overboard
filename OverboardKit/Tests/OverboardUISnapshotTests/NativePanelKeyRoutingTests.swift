import AppKit
import OverboardCore
@testable import OverboardUI
import Testing

@MainActor
struct NativePanelKeyRoutingTests {
    @Test func returnActionsUseExactModifiers() {
        #expect(PanelActionID.commit(for: []) == .paste)
        #expect(PanelActionID.commit(for: .command) == .copy)
        #expect(PanelActionID.commit(for: .shift) == .plainPaste)
        #expect(PanelActionID.commit(for: [.command, .shift]) == .stack)
        #expect(PanelActionID.commit(for: [.command, .capsLock, .numericPad]) == .copy)
        for flags: NSEvent.ModifierFlags in [.option, .control, [.command, .option], [.command, .control]] {
            #expect(PanelActionID.commit(for: flags) == nil)
        }
    }

    @Test func compositionDialogsAndEditorsAlwaysWin() {
        for focus: PanelKeyFocus in [.markedText, .dialog, .editor, .control] {
            for key: KeyCode in [.returnKey, .keypadEnter, .escape, .leftArrow, .downArrow, .letterK] {
                #expect(NativePanelKeyRouting.shouldDefer(keyCode: key.rawValue, modifiers: .command, focus: focus))
            }
        }
    }

    @Test func caretAndNativeFocusNavigationWinOverResults() {
        for key: KeyCode in [.leftArrow, .rightArrow] {
            #expect(NativePanelKeyRouting.shouldDefer(
                keyCode: key.rawValue, modifiers: [], focus: .search(hasText: true)
            ))
            #expect(!NativePanelKeyRouting.shouldDefer(
                keyCode: key.rawValue, modifiers: [], focus: .search(hasText: false)
            ))
        }
        #expect(NativePanelKeyRouting.shouldDefer(keyCode: KeyCode.tab.rawValue, modifiers: [], focus: .results))
        #expect(NativePanelKeyRouting.shouldDefer(
            keyCode: KeyCode.upArrow.rawValue, modifiers: .command, focus: .search(hasText: true)
        ))
        #expect(!NativePanelKeyRouting.shouldDefer(
            keyCode: KeyCode.downArrow.rawValue, modifiers: .shift, focus: .results
        ))
        #expect(!NativePanelKeyRouting.shouldDefer(
            keyCode: KeyCode.returnKey.rawValue, modifiers: [], focus: .search(hasText: true)
        ))
    }

    @Test func appKitMarkedTextIsDetectedBeforeFieldEditor() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: window.contentLayoutRect)
        editor.isFieldEditor = true
        editor.string = "query"
        window.contentView = editor
        #expect(window.makeFirstResponder(editor))
        #expect(NativePanelKeyRouting.focus(in: window) == .search(hasText: true))
        editor.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        #expect(NativePanelKeyRouting.focus(in: window) == .markedText)
        editor.unmarkText()
        editor.isFieldEditor = false
        #expect(NativePanelKeyRouting.focus(in: window) == .editor)
    }
}
