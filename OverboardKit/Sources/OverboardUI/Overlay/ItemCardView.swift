import AppKit
import OverboardCore
import SwiftUI

struct ItemCardView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let store: ClipStore
    var applicableActions: [ClipAction] = []
    var onRunAction: (ClipAction) -> Void = { _ in }
    var onPinToggle: () -> Void = {}
    var onDelete: () -> Void = {}
    var onPaste: (PasteMode) -> Void = { _ in }
    var onTransform: (ClipTransform) -> Void = { _ in }
    var onAITransform: (AITransform) -> Void = { _ in }
    var onPreview: () -> Void = {}

    /// `internal`: read from `loadThumbnailIfNeeded()` in
    /// ItemCardView+Loading.swift, in addition to this file.
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    /// Cards are a fixed grid of equal tiles, so the tile itself has to grow
    /// with the type inside it.
    @ScaledMetric(relativeTo: .callout) private var cardWidth: CGFloat = CardMetrics.width
    /// `internal`: read from `textPreviewLineLimit` in ItemCardView+Bodies.swift.
    @ScaledMetric(relativeTo: .callout) var cardHeight: CGFloat = CardMetrics.height
    /// `internal`: read in ItemCardView+Bodies.swift, set from
    /// ItemCardView+Loading.swift.
    @State var thumbnail: NSImage?
    @State private var hovering = false
    @State var miniCode: NSAttributedString?
    /// The (length-capped) source text behind `miniCode`, kept so a
    /// colorScheme flip can re-highlight without re-fetching from the store.
    /// `internal`: set from ItemCardView+Loading.swift.
    @State var miniCodeSource: String?
    @State var swatch: NSColor?
    @State var faviconImage: NSImage?
    @State var linkPreviewImage: NSImage?
    /// Dominant color of the source app's icon, for the tinted header
    /// gradient — computed once per `.task(id:)` pass instead of during
    /// every layout pass. `internal`: set from ItemCardView+Loading.swift.
    @State var headerTint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider().opacity(0.4)
            self.content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            self.footer
        }
        .frame(width: self.cardWidth, height: self.cardHeight)
        .background(.background.opacity(0.6))
        // Clip the whole card so image fills can't bleed past the corners.
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    self.isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                    lineWidth: self.isSelected ? 2.5 : 1
                )
        }
        .overlay(alignment: .topTrailing) {
            if self.hovering {
                self.hoverActions
            }
        }
        .scaleEffect(self.isSelected ? 1.04 : 1)
        .shadow(
            color: .black.opacity(self.isSelected ? 0.28 : 0),
            radius: self.isSelected ? 9 : 0,
            y: 4
        )
        .motion(.spring(response: 0.25, dampingFraction: 0.7), value: self.isSelected)
        .motion(.easeOut(duration: 0.12), value: self.hovering)
        .onHover { self.hovering = $0 }
        .task(id: self.item.id) {
            await self.loadThumbnailIfNeeded()
        }
        .onChange(of: self.colorScheme) {
            guard let source = self.miniCodeSource else { return }
            Task { self.miniCode = await CodeHighlighter.highlight(source, dark: self.colorScheme == .dark) }
        }
        .contextMenu {
            Button("Paste") { self.onPaste(.full) }
            if self.item.kind == .text || self.item.kind == .link {
                Button("Paste as Plain Text") { self.onPaste(.plainText) }
            }
            let transforms = ClipTransform.allCases.filter { $0.applies(to: self.item.kind) }
            if !transforms.isEmpty, !self.item.isSecret {
                Menu("Paste Transformed") {
                    ForEach(transforms) { transform in
                        Button(transform.label) { self.onTransform(transform) }
                    }
                }
            }
            if self.item.kind == .text, !self.item.isSecret, AITransformer.isAvailable {
                Menu("Paste with AI") {
                    ForEach(AITransform.allCases) { transform in
                        Button(transform.label) { self.onAITransform(transform) }
                    }
                }
            }
            if !self.applicableActions.isEmpty {
                Divider()
                ForEach(self.applicableActions) { action in
                    Button {
                        self.onRunAction(action)
                    } label: {
                        Label(action.label, systemImage: action.systemImage)
                    }
                }
            }
            Divider()
            Button(self.item.isPinned ? "Unpin" : "Pin") { self.onPinToggle() }
            Button("Delete", role: .destructive) { self.onDelete() }
        }
        .onDrag {
            Self.dragProvider(for: self.item, store: self.store)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityCardLabel)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    /// VoiceOver summary for the whole card: source app plus a short preview,
    /// so the card reads as one item instead of its individual subviews.
    private var accessibilityCardLabel: String {
        let app = self.item.sourceAppName ?? self.item.kind.displayName
        if self.item.isSecret {
            return "\(app), secret item"
        }
        let preview = self.item.previewText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preview, !preview.isEmpty {
            return "\(app), \(preview)"
        }
        return app
    }

    /// Quick actions that fade in on hover so mouse users skip the context menu.
    private var hoverActions: some View {
        HStack(spacing: 4) {
            self.hoverButton("eye", label: "Preview") { self.onPreview() }
            self.hoverButton(
                self.item.isPinned ? "pin.slash" : "pin",
                label: self.item.isPinned ? "Unpin" : "Pin"
            ) { self.onPinToggle() }
            self.hoverButton("trash", label: "Delete") { self.onDelete() }
        }
        .padding(5)
        .background(.regularMaterial, in: Capsule())
        .padding(6)
        .transition(.opacity)
    }

    private func hoverButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = AppIconCache.shared.icon(forBundleID: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(self.item.sourceAppName ?? self.item.kind.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let category = item.category, ClipEnricher.badgeCategories.contains(category) {
                Text(category)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if self.item.isSecret {
                // A yellow glyph on glass was easy to miss on the one card where
                // misreading the content matters most; a filled capsule reads as
                // a warning at any contrast setting.
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                    Text("Secret")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.orange, in: Capsule())
                .accessibilityHidden(true)
            }
            if self.item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if self.index < 9 {
                Text("⌘\(self.index + 1)")
                    .font(.caption2.monospaced())
                    .contrastAwareForeground(.tertiary)
                    .accessibilityLabel("Command \(self.index + 1)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            // Paste-style signature: header tinted by the source app's icon.
            // Increase Contrast drops the gradient: an arbitrary app-icon color
            // behind the source name is exactly the kind of low-contrast pairing
            // the setting exists to remove.
            if let tint = self.headerTint, self.contrast != .increased {
                LinearGradient(
                    colors: [tint.opacity(0.45), tint.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                Color.primary.opacity(0.05)
            }
        }
    }

    static func hexString(for color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "—" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
