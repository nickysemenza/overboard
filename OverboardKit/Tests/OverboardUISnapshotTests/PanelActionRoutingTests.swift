import Foundation
import OverboardCore
@testable import OverboardUI
import Testing

@Suite(.serialized)
@MainActor
struct PanelActionRoutingTests {
    @Test func sharedMetadataMatchesDrawerAndLauncherIdentity() {
        #expect(Set(PanelActionID.allCases.map(\.rawValue)).count == PanelActionID.allCases.count)
        for command in DrawerCommand.allCases {
            guard let action = command.sharedAction else { continue }
            #expect(DrawerPaletteEntry.command(command).id == action.rawValue)
            #expect(command.keycap == action.metadata.shortcut)
            #expect(command.systemImage == action.metadata.systemImage)
        }
        #expect(LauncherPaletteEntry.action(.paste).id == PanelActionID.paste.rawValue)
        #expect(LauncherPaletteEntry.action(.copy).id == PanelActionID.copy.rawValue)
        #expect(LauncherPaletteEntry.action(.pastePlain).id == PanelActionID.plainPaste.rawValue)
        #expect(LauncherPaletteEntry.stack.id == PanelActionID.stack.rawValue)
    }

    @Test func launcherCommitsByActionNotPosition() async {
        let item = Fixtures.item(preview: "shared clipboard action")
        let model = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.clip(item)])
        var pasted: [PasteMode] = []
        var copied: [String] = []
        var stacked: [String] = []
        model.onPasteClip = { _, mode in pasted.append(mode) }
        model.onCopyClip = { copied.append($0.id) }
        model.performPanelCommit(.paste)
        model.performPanelCommit(.copy)
        model.performPanelCommit(.plainPaste)
        model.performPanelCommit(.stack) { stacked.append($0.id) }
        #expect(pasted == [.full, .plainText])
        #expect(copied == [item.id])
        #expect(stacked == [item.id])

        let calculation = LauncherResult.calculation(input: "6 * 7", display: "42")
        let calculator = await LauncherCommitRoutingFixtures.makeViewModel(rows: [calculation])
        var operations: [String] = []
        calculator.onPasteText = { operations.append("paste:\($0)") }
        calculator.onCopyText = { operations.append("copy:\($0)") }
        calculator.performPanelCommit(.paste)
        calculator.performPanelCommit(.copy)
        #expect(operations == ["paste:42", "copy:42"])
        calculator.paletteQuery = "calculation"
        #expect(calculator.filteredPaletteEntries(includeStack: false) == [.copyCalculation])
        #expect(LauncherPaletteEntry.copyCalculation.id == "copyCalculation")
        #expect(LauncherPaletteEntry.copyCalculation.label == "Copy Calculation")
        calculator.runPaletteEntry()
        #expect(operations == ["paste:42", "copy:42", "copy:42"])

        let conversion = await LauncherCommitRoutingFixtures.makeViewModel(
            rows: [.calculation(input: "2 km in m", display: "2,000 m")]
        )
        var converted: [String] = []
        conversion.onPasteText = { converted.append("paste:\($0)") }
        conversion.onCopyText = { converted.append("copy:\($0)") }
        conversion.performPanelCommit(.paste)
        conversion.performPanelCommit(.copy)
        #expect(converted == ["paste:2,000 m", "copy:2,000 m"])
    }

    @Test func filteredLauncherPaletteDispatchesDisplayedIdentity() async {
        let item = Fixtures.item(preview: "filter these actions")
        let model = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.clip(item)])
        var stacked: [String] = []
        var copied: [String] = []
        model.onCopyClip = { copied.append($0.id) }
        model.togglePalette()
        model.paletteQuery = "stack"
        #expect(model.filteredPaletteEntries(includeStack: true) == [.stack])
        #expect(model.filteredPaletteEntries(includeStack: false).isEmpty)
        model.runPaletteEntry(onAddClipToStack: { stacked.append($0.id) })
        #expect(stacked == [item.id])
        #expect(!model.isPaletteOpen)
        model.togglePalette()
        model.paletteQuery = "copy"
        #expect(model.filteredPaletteEntries(includeStack: true) == [.action(.copy)])
        model.runPaletteEntry()
        #expect(copied == [item.id])
    }

    @Test func drawerUsesTheSameCommitContract() throws {
        let model = try DrawerViewModel(store: Fixtures.store(), stack: PasteStack())
        let item = Fixtures.item(preview: "drawer action")
        model.items = [item]
        var pasted: [PasteMode] = []
        var copied: [String] = []
        model.onCommit = { _, mode in pasted.append(mode) }
        model.onCopyClip = { copied.append($0.id) }
        model.performPanelAction(.paste)
        model.performPanelAction(.copy)
        model.performPanelAction(.plainPaste)
        model.performPanelAction(.stack)
        #expect(pasted == [.full, .plainText])
        #expect(copied == [item.id])
        #expect(model.stack.count == 1)
        model.items = [Fixtures.item(kind: .image, preview: "image")]
        model.performPanelAction(.plainPaste)
        #expect(pasted.count == 2)
    }

    @Test func drawerPalettePreservesShortcutsAndFilteredDispatch() throws {
        let model = try DrawerViewModel(store: Fixtures.store(), stack: PasteStack())
        let item = Fixtures.item(preview: "palette shortcut fixture")
        model.items = [item]
        let palette = try #require(ActionPalette(viewModel: model).body as? CommandPaletteView)
        for (index, entry) in model.filteredPaletteActions.enumerated() {
            #expect(palette.items[index].id == entry.id)
            #expect(palette.items[index].hint == (entry.hint ?? (index == model.paletteIndex ? "↩" : nil)))
        }
        model.paletteQuery = "copy"
        let filteredPalette = try #require(ActionPalette(viewModel: model).body as? CommandPaletteView)
        #expect(filteredPalette.items.map(\.id) == [PanelActionID.copy.rawValue])
        #expect(filteredPalette.items.map(\.hint) == [PanelActionID.copy.metadata.shortcut])
        var copied: [String] = []
        model.onCopyClip = { copied.append($0.id) }
        filteredPalette.onRun(0)
        #expect(copied == [item.id])
    }
}
