@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

@MainActor
struct NativeChromeSnapshotTests {
    @Test func measuredScrollablePalette() {
        let items = (0 ..< 16).map { index in
            CommandPaletteItem(id: "action-\(index)", label: "Action \(index + 1)", systemImage: "doc",
                               hint: index == 0 ? "↩" : nil)
        }
        let view = CommandPaletteView(items: items, query: .constant(""), index: .constant(0),
                                      emptyMessage: "No actions", onRun: { _ in }, maximumHeight: 180)
        assertSnapshot(of: snapshotImage(view, width: 420, height: 220), as: snapshotImageStrategy,
                       record: snapshotRecordingMode)
    }

    @Test func footerPasteToAppAndCopy() {
        let view = PanelFooterBar(
            primary: .init(label: "Paste to Notes", handler: {}),
            secondary: .init(label: PanelActionID.copy.metadata.label,
                             keycap: PanelActionID.copy.metadata.shortcut, handler: {})
        ).padding(16)
        assertSnapshot(of: snapshotImage(view, width: 420, height: 70), as: snapshotImageStrategy,
                       record: snapshotRecordingMode)
        assertSnapshot(of: snapshotImage(view, width: 420, height: 70, dark: true), as: snapshotImageStrategy,
                       record: snapshotRecordingMode)
    }
}
