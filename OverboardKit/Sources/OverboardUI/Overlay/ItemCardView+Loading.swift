import ImageIO
import OverboardCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Thumbnail / preview loading

extension ItemCardView {
    func loadThumbnailIfNeeded() async {
        // Header tint runs for every kind, so it lives outside the switch.
        self.headerTint = AppIconCache.shared.tint(forBundleID: self.item.sourceBundleID)
        switch self.item.kind {
        case .image:
            await self.loadImageThumbnail()
        case .text:
            await self.loadCodeHighlight()
        case .color:
            await self.loadColorSwatch()
        case .link:
            self.loadLinkImages()
        case .file:
            break
        }
    }

    private func loadImageThumbnail() async {
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
    }

    private func loadCodeHighlight() async {
        guard self.miniCode == nil, !self.item.isSecret,
              self.item.category == "code",
              let text = try? await store.plainText(for: item.id)
        else { return }
        let capped = String(text.prefix(500))
        self.miniCodeSource = capped
        let highlighted = await CodeHighlighter.highlight(capped, dark: self.colorScheme == .dark)
        guard !Task.isCancelled else { return }
        self.miniCode = highlighted
    }

    private func loadColorSwatch() async {
        guard self.swatch == nil,
              let rep = try? await store.representations(for: item.id)
              .first(where: { $0.uti == WellKnownUTI.color }),
              let data = try? await store.payload(for: rep)
        else { return }
        self.swatch = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    /// Already-fetched bytes on the model — just decode once here instead of
    /// on every body evaluation.
    private func loadLinkImages() {
        if self.faviconImage == nil, let data = item.faviconData, !data.isEmpty {
            self.faviconImage = NSImage(data: data)
        }
        if self.linkPreviewImage == nil, let data = item.previewImageData, !data.isEmpty {
            self.linkPreviewImage = NSImage(data: data)
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
}

// MARK: - Drag out

extension ItemCardView {
    /// Builds a provider whose payloads load lazily from the store when the
    /// drop target asks for them.
    nonisolated static func dragProvider(for item: ClipItem, store: ClipStore) -> NSItemProvider {
        let provider = NSItemProvider()

        func register(typeID: String, uti: String, transform: (@Sendable (Data) -> Data?)? = nil) {
            provider.registerDataRepresentation(
                forTypeIdentifier: typeID,
                visibility: .all
            ) { completion in
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
