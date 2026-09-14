import AppKit
import OverboardCore
import SwiftUI

// MARK: - Preview / edit

public extension DrawerViewModel {
    /// Drives the preview pane's show/hide in `DrawerView`, applied to
    /// `previewState` there via `.motion(_:value:)`. SwiftUI owns the whole
    /// transition; the panel resize in `OverlayController+Panel.swift` is an
    /// instant, invisible AppKit frame snap, so this spring is the only
    /// motion the user actually sees.
    static let previewMotion = Animation.spring(response: 0.28, dampingFraction: 0.86)

    var selectedItem: ClipItem? {
        self.mode == .history && self.items.indices.contains(self.selectedIndex)
            ? self.items[self.selectedIndex] : nil
    }

    func togglePreview() {
        switch self.previewState {
        case .hidden:
            guard self.selectedItem != nil else { return }
            // Grow the panel to its expanded height BEFORE the content
            // transitions in. The panel is transparent, so growing early is
            // invisible — but growing AFTER would let SwiftUI lay the
            // incoming PreviewPane out inside the still-collapsed frame,
            // clipping or squeezing it until the resize catches up.
            self.onPreviewVisibilityChanged(true)
            withAnimation(self.motion) {
                self.previewState = .viewing
            }
        case .viewing, .editing:
            self.closePreview()
        }
    }

    func closePreview() {
        guard self.previewState != .hidden else { return }
        // Shrink only AFTER the content has finished animating out: the
        // panel is bottom-anchored (OverlayController+Panel.swift), so
        // shrinking early would cut off the outgoing content mid-transition
        // instead of letting it settle inside the still-expanded frame.
        withAnimation(self.motion) {
            self.previewState = .hidden
        } completion: {
            // Space twice within the spring reopens the pane before this
            // fires; shrinking then would clip the pane that's now showing.
            guard self.previewState == .hidden else { return }
            self.onPreviewVisibilityChanged(false)
        }
    }

    /// `nil` under Reduce Motion, so the state change lands instantly —
    /// `withAnimation(nil) { … } completion:` still invokes the completion,
    /// so `closePreview()` doesn't need to special-case this.
    private var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Self.previewMotion
    }

    func beginEdit() {
        guard let item = self.selectedItem,
              item.kind == .text || item.kind == .link
        else { return }
        let wasHidden = self.previewState == .hidden
        Task {
            self.editText = await (try? self.store.plainText(for: item.id))
                ?? item.previewText ?? ""
            self.previewState = .editing
            if wasHidden {
                self.onPreviewVisibilityChanged(true)
            }
        }
    }

    func commitEdit() {
        guard self.previewState == .editing else { return }
        let text = self.editText
        self.closePreview()
        self.onCommitEditedText(text)
    }
}
