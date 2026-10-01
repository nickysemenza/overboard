import AppKit
import OverboardCore
import OverboardUI

extension AppServices {
    func invokeQuicklink(_ quicklink: Quicklink, with item: ClipItem) {
        guard self.libraryRecovery == nil, !item.isSecret else { return }
        Task {
            do {
                guard try await self.store.isEnrichmentEligible(itemID: item.id),
                      let text = try await self.store.plainText(for: item.id),
                      ClipSensitivity.label(for: text) == nil,
                      let destination = quicklink.destination(for: .clipboard(text)),
                      try await self.store.isEnrichmentEligible(itemID: item.id)
                else {
                    HUDController.shared.flash("This item cannot be sent to this quicklink")
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Open \(quicklink.name)?"
                alert.informativeText = "The selected clipboard item will be sent to this destination. " +
                    "Review the full address before opening it."
                alert.accessoryView = Self.quicklinkDestinationPreview(destination.url)
                alert.addButton(withTitle: "Open Destination")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate()
                guard alert.runModal() == .alertFirstButtonReturn,
                      try await self.store.isEnrichmentEligible(itemID: item.id)
                else { return }
                guard NSWorkspace.shared.open(destination.url) else {
                    HUDController.shared.flash("Couldn't open the quicklink destination")
                    return
                }
            } catch {
                HUDController.shared.flash("Couldn't prepare the selected clipboard item")
                self.logger.error("Selected clipboard quicklink failed")
            }
        }
    }

    private static func quicklinkDestinationPreview(_ destination: URL) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 160))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.string = destination.absoluteString
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular
        )
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Quicklink destination")
        scrollView.documentView = textView
        return scrollView
    }
}
