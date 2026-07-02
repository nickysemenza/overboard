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
    var applicableActions: [ClipAction] = []
    var onRunAction: (ClipAction) -> Void = { _ in }
    var onPinToggle: () -> Void = {}
    var onDelete: () -> Void = {}
    var onPaste: (PasteMode) -> Void = { _ in }
    var onTransform: (ClipTransform) -> Void = { _ in }
    var onAITransform: (AITransform) -> Void = { _ in }
    var onPreview: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnail: NSImage?
    @State private var hovering = false
    @State private var miniCode: NSAttributedString?
    @State private var swatch: NSColor?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider().opacity(0.4)
            self.content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            self.footer
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
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: self.isSelected)
        .onHover { self.hovering = $0 }
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
    }

    /// Quick actions that fade in on hover so mouse users skip the context menu.
    private var hoverActions: some View {
        HStack(spacing: 4) {
            self.hoverButton("eye") { self.onPreview() }
            self.hoverButton(self.item.isPinned ? "pin.slash" : "pin") { self.onPinToggle() }
            self.hoverButton("trash") { self.onDelete() }
        }
        .padding(5)
        .background(.regularMaterial, in: Capsule())
        .padding(6)
        .offset(y: 26)
        .transition(.opacity)
    }

    private func hoverButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
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
        .background {
            // Paste-style signature: header tinted by the source app's icon.
            if let tint = AppIconCache.shared.tint(forBundleID: item.sourceBundleID) {
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
            } else if let miniCode {
                // Mini syntax-highlighted code straight on the card.
                CodeTextView(attributed: miniCode, selectable: false)
                    .allowsHitTesting(false)
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
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(self.linkHost ?? "link")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Text(self.item.previewText ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                if let title = item.aiTitle {
                    Spacer(minLength: 0)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 3)
            }
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
                        let dims = self.item.metadataFooter
                        if self.item.aiTitle != nil || dims != nil {
                            HStack(spacing: 6) {
                                if let title = item.aiTitle {
                                    Text(title)
                                        .font(.caption2.weight(.medium))
                                        .lineLimit(1)
                                }
                                if self.item.aiTitle != nil, dims != nil {
                                    Spacer(minLength: 0)
                                }
                                if let dims {
                                    Text(dims)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
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
            if let swatch {
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: swatch))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                        }
                    Text(Self.hexString(for: swatch))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            } else {
                self.placeholder("paintpalette.fill")
            }
        }
    }

    /// Metadata line under the card content (char/line counts, file size…).
    /// Images carry their dimensions in the image overlay instead, so they get
    /// no footer row here. Nil metadata renders nothing — no placeholder.
    @ViewBuilder
    private var footer: some View {
        if self.item.kind != .image, let text = item.metadataFooter {
            Divider().opacity(0.25)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    private var linkHost: String? {
        guard let text = item.previewText,
              let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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

    /// Raw text yields lines to the title and summary when they're present.
    /// One line is reserved for the metadata footer row (see `footer`).
    private var textPreviewLineLimit: Int {
        switch (self.item.aiTitle != nil, self.item.aiSummary != nil) {
        case (false, false): 6
        case (true, false): 5
        case (false, true): 3
        case (true, true): 2
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
        switch self.item.kind {
        case .image:
            guard self.thumbnail == nil,
                  let rep = try? await store.representations(for: item.id)
                  .first(where: { $0.uti == WellKnownUTI.png })
            else { return }
            // Downsample straight off the blob file when possible so a large
            // image never fully inflates in memory just to draw a small card.
            if let url = await store.blobURL(for: rep),
               let cgImage = ImageDownsampler.downsampledImage(fromURL: url, maxPixel: 480)
            {
                self.thumbnail = NSImage(cgImage: cgImage, size: .zero)
            } else if let data = try? await store.payload(for: rep) {
                self.thumbnail = Self.thumbnail(from: data, maxPixel: 480)
            }

        case .text:
            guard self.miniCode == nil, !self.item.isSecret,
                  self.item.category == "code",
                  let text = try? await store.plainText(for: item.id)
            else { return }
            self.miniCode = CodeHighlighter.highlight(
                String(text.prefix(500)),
                dark: self.colorScheme == .dark
            )

        case .color:
            guard self.swatch == nil,
                  let rep = try? await store.representations(for: item.id)
                  .first(where: { $0.uti == WellKnownUTI.color }),
                  let data = try? await store.payload(for: rep)
            else { return }
            self.swatch = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)

        default:
            break
        }
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
    private var tintCache: [String: Color?] = [:]

    func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        self.cache[bundleID] = icon
        return icon
    }

    /// Dominant color of the app's icon (average pixel), for tinted headers.
    func tint(forBundleID bundleID: String?) -> Color? {
        guard let bundleID else { return nil }
        if let cached = tintCache[bundleID] { return cached }
        let tint = self.icon(forBundleID: bundleID).flatMap(Self.averageColor)
        self.tintCache[bundleID] = tint
        return tint
    }

    private static func averageColor(of image: NSImage) -> Color? {
        guard let context = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let pixel = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let alpha = Double(pixel[3]) / 255
        guard alpha > 0.1 else { return nil }
        // Un-premultiply so transparent icon edges don't darken the tint.
        return Color(
            red: Double(pixel[0]) / 255 / alpha,
            green: Double(pixel[1]) / 255 / alpha,
            blue: Double(pixel[2]) / 255 / alpha
        )
    }
}
