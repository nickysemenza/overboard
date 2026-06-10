import AppKit
import ImageIO
import OverboardCore
import SwiftUI
import UniformTypeIdentifiers

struct ItemCardView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let store: ClipStore
    var onPinToggle: () -> Void = {}
    var onDelete: () -> Void = {}
    var onPaste: (PasteMode) -> Void = { _ in }
    var onTransform: (ClipTransform) -> Void = { _ in }
    var onAITransform: (AITransform) -> Void = { _ in }

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider().opacity(0.4)
            self.content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 190, height: 180)
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
        .task(id: self.item.id) {
            await self.loadThumbnailIfNeeded()
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
            Divider()
            Button(self.item.isPinned ? "Unpin" : "Pin") { self.onPinToggle() }
            Button("Delete", role: .destructive) { self.onDelete() }
        }
        .onDrag {
            Self.dragProvider(for: self.item, store: self.store)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = AppIconCache.shared.icon(forBundleID: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(self.item.sourceAppName ?? self.kindLabel)
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
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            if self.item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if self.index < 9 {
                Text("⌘\(self.index + 1)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background.opacity(0.5))
    }

    @ViewBuilder
    private var content: some View {
        switch self.item.kind {
        case .text:
            if self.item.isSecret {
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.title)
                        .foregroundStyle(.yellow)
                    Text(self.item.previewText ?? "Secret")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Auto-expires soon")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = item.aiTitle {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(self.item.previewText ?? "")
                        .font(.callout)
                        .lineLimit(self.textPreviewLineLimit)
                    if let summary = item.aiSummary {
                        Spacer(minLength: 0)
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(summary)
                                .font(.caption)
                                .italic()
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(10)
            }
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                Text(self.item.previewText ?? "")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(5)
            }
            .padding(10)
        case .image:
            if let thumbnail {
                // Color.clear.overlay + clipped is the canonical
                // non-bleeding aspect-fill: the image can never propose its
                // own size to the layout.
                Color.clear
                    .overlay {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .overlay(alignment: .bottom) {
                        if let title = item.aiTitle {
                            Text(title)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity)
                                .background(.ultraThinMaterial)
                        }
                    }
            } else {
                self.placeholder("photo")
            }
        case .file:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(self.item.previewText ?? "")
                    .font(.callout)
                    .lineLimit(4)
            }
            .padding(10)
        case .color:
            self.placeholder("paintpalette.fill")
        }
    }

    /// Raw text yields lines to the title and summary when they're present.
    private var textPreviewLineLimit: Int {
        switch (self.item.aiTitle != nil, self.item.aiSummary != nil) {
        case (false, false): 7
        case (true, false): 6
        case (false, true): 4
        case (true, true): 3
        }
    }

    private func placeholder(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.largeTitle)
            .foregroundStyle(.quaternary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var kindLabel: String {
        switch self.item.kind {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }

    private func loadThumbnailIfNeeded() async {
        guard self.item.kind == .image, self.thumbnail == nil else { return }
        guard let rep = try? await store.representations(for: item.id)
            .first(where: { $0.uti == WellKnownUTI.png }),
            let data = try? await store.payload(for: rep)
        else { return }
        self.thumbnail = Self.thumbnail(from: data, maxPixel: 480)
    }

    nonisolated static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    // MARK: - Drag out

    /// Builds a provider whose payloads load lazily from the store when the
    /// drop target asks for them.
    nonisolated static func dragProvider(for item: ClipItem, store: ClipStore) -> NSItemProvider {
        let provider = NSItemProvider()

        func register(typeID: String, uti: String, transform: (@Sendable (Data) -> Data?)? = nil) {
            provider.registerDataRepresentation(
                forTypeIdentifier: typeID,
                visibility: .all
            ) { completion in
                nonisolated(unsafe) let completion = completion
                Task {
                    do {
                        let reps = try await store.representations(for: item.id)
                        guard let rep = reps.first(where: { $0.uti == uti }) else {
                            completion(nil, CocoaError(.fileNoSuchFile))
                            return
                        }
                        let data = try await store.payload(for: rep)
                        completion(transform?(data) ?? data, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
                return nil
            }
        }

        switch item.kind {
        case .text:
            register(typeID: UTType.utf8PlainText.identifier, uti: WellKnownUTI.plainText)
            register(typeID: UTType.rtf.identifier, uti: WellKnownUTI.rtf)
        case .link:
            register(typeID: UTType.url.identifier, uti: WellKnownUTI.plainText)
            register(typeID: UTType.utf8PlainText.identifier, uti: WellKnownUTI.plainText)
        case .image:
            register(typeID: UTType.png.identifier, uti: WellKnownUTI.png)
        case .file:
            // Drag carries the first file's URL; multi-file drag-out can come later.
            register(typeID: UTType.fileURL.identifier, uti: WellKnownUTI.fileURLs) { data in
                guard let strings = try? JSONDecoder().decode([String].self, from: data),
                      let first = strings.first
                else { return nil }
                return Data(first.utf8)
            }
        case .color:
            break
        }
        return provider
    }
}

/// Resolves and caches app icons by bundle ID. Icons are looked up lazily —
/// we never persist them.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage?] = [:]

    func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        self.cache[bundleID] = icon
        return icon
    }
}
