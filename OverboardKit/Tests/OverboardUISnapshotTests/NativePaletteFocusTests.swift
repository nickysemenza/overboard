import AppKit
import OverboardCore
@testable import OverboardUI
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct NativePaletteFocusTests {
    @Test func drawerPaletteOwnsTypingInsteadOfClipboardSearch() async throws {
        let model = try DrawerViewModel(store: Fixtures.store(), stack: PasteStack())
        model.query = "standup"
        model.items = [Fixtures.item(preview: "standup clipboard")]
        let window = self.makeWindow(rootView: DrawerView(viewModel: model))
        defer { window.close() }
        let content = try #require(window.contentView)
        let field = try #require(self.textFields(in: content).first)
        #expect(window.makeFirstResponder(field))
        model.togglePalette()
        await self.layout(window)
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.string.isEmpty)
        editor.insertText("copy", replacementRange: NSRange(location: NSNotFound, length: 0))
        await self.layout(window)
        #expect(model.query == "standup")
        #expect(model.paletteQuery == "copy")
        model.closePalette()
        await self.layout(window)
        #expect((window.firstResponder as? NSTextView)?.string == "standup")
    }

    @Test func browserPaletteOwnsTypingInsteadOfClipboardSearch() async throws {
        let model = await LauncherCommitRoutingFixtures.makeViewModel(rows: [
            .clip(Fixtures.item(preview: "browser clipboard")),
        ])
        model.scope = .clipboard
        let window = try self.makeWindow(rootView: LauncherView(viewModel: model, store: Fixtures.store()))
        defer { window.close() }
        let content = try #require(window.contentView)
        let field = try #require(self.textFields(in: content).first)
        #expect(window.makeFirstResponder(field))
        model.togglePalette()
        await self.layout(window)
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.string.isEmpty)
        editor.insertText("copy", replacementRange: NSRange(location: NSNotFound, length: 0))
        await self.layout(window)
        #expect(model.query == "zzz")
        #expect(model.paletteQuery == "copy")
        model.closePalette()
        await self.layout(window)
        #expect((window.firstResponder as? NSTextView)?.string == "zzz")
    }

    private func makeWindow(rootView: some View) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = PanelHosting.container(
            rootView: rootView.environment(\.skipsEntranceMotion, true), frame: window.contentLayoutRect
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { self.textFields(in: $0) }
    }

    private func layout(_ window: NSWindow) async {
        for _ in 0 ..< 10 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
