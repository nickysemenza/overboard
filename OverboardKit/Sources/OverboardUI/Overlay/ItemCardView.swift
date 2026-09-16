import AppKit
import OverboardCore
import SwiftUI

struct ItemCardView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let store: ClipStore
    var applicableActions: [ClipAction] = []
    /// True when the card strip's frecency order put this item above a
    /// strictly newer neighbor (see `DrawerViewModel.StripEntry`). Defaults to
    /// false so previews and snapshot tests that construct a card directly
    /// don't all need to opt in.
    var rankedAboveNewer: Bool = false
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
    /// `internal`: read from `footer` in ItemCardView+Bodies.swift.
    @Environment(\.referenceDate) var referenceDate
    /// Cards are a fixed grid of equal tiles, so the tile itself has to grow
    /// with the type inside it — `cardShell` owns the matching width metric.
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
        // Applied before `cardShell` so the hover pill scales and lifts with
        // the card's selected-state transform instead of sitting outside it.
        .overlay(alignment: .topTrailing) {
            if self.hovering {
                self.hoverActions
            }
        }
        .cardShell(isSelected: self.isSelected)
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
        // Folds in the use count the same way the absolute time already
        // rides along in this clause — "copied 4 times, <date>" — instead of
        // being a separate footer-only detail VoiceOver users can't reach.
        let copied = ", \(self.copiedCountPhrase.lowercased()), \(TimestampFormatter.absolute(self.item.lastUsedAt))"
        if self.item.isSecret {
            return "\(app), secret item\(copied)"
        }
        let preview = self.item.previewText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preview, !preview.isEmpty {
            return "\(app), \(preview)\(copied)"
        }
        return "\(app)\(copied)"
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
                // Only the pin glyph actually swaps ("pin" ↔ "pin.slash"); a
                // plain crossfade beats the glyph just popping between states.
                .contentTransition(.symbolEffect(.replace))
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
                SecretBadge()
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
