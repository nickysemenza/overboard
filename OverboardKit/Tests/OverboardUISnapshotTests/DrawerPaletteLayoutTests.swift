import AppKit
import OverboardCore
@testable import OverboardUI
import Testing

@MainActor
struct DrawerPaletteLayoutTests {
    @Test(arguments: [PreviewState.hidden, .viewing])
    func paletteStaysAboveReservedFooter(previewState: PreviewState) throws {
        let model = try DrawerViewModel(store: Fixtures.store(), stack: PasteStack())
        model.items = [Fixtures.item(preview: "drawer palette layout fixture")]
        model.previewState = previewState
        model.isPaletteOpen = true
        let height = previewState == .hidden ? CardMetrics.collapsedPanelHeight : CardMetrics.expandedPanelHeight
        let host = snapshotHost(DrawerView(viewModel: model), width: 900, height: height)
        let footerTop = height - DrawerView.outerPadding - 14 - PanelFooterBar.height
        let queryField = try #require(self.views(of: NativePaletteQueryField.MountedField.self, in: host).first)
        #expect(queryField.convert(queryField.bounds, to: host).maxY < footerTop)
        let paletteScrollViews = self.views(of: NSScrollView.self, in: host).filter {
            $0.bounds.width <= 380 && $0.bounds.height > 0
        }
        try #require(!paletteScrollViews.isEmpty)
        for scrollView in paletteScrollViews {
            #expect(scrollView.convert(scrollView.bounds, to: host).maxY < footerTop)
        }
    }

    private func views<ViewType: NSView>(of type: ViewType.Type, in view: NSView) -> [ViewType] {
        let matches = (view as? ViewType).map { [$0] } ?? []
        return matches + view.subviews.flatMap { self.views(of: type, in: $0) }
    }
}
