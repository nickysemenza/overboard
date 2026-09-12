import AppKit
import OverboardCore
import OverboardFilePreview
import OverboardMac
import Quartz
import SwiftUI

struct SearchHighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(self.highlighted)
    }

    private var highlighted: AttributedString {
        var result = AttributedString(self.text)
        for match in SearchMatcher.highlights(in: self.text, query: self.query) {
            guard let range = Range(match, in: self.text),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start ..< end].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}

enum FileBreadcrumb {
    static func label(_ url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "/Library/Mobile Documents/com~apple~CloudDocs") {
            return "iCloud Drive" + path[range.upperBound...].replacingOccurrences(of: "/", with: " › ")
        }
        if let range = path.range(of: "/Library/CloudStorage/") {
            return path[range.upperBound...].replacingOccurrences(of: "/", with: " › ")
        }
        // Paths outside the home directory come back from `abbreviatingWithTildeInPath`
        // unabbreviated (still leading with "/"), which would otherwise turn into a
        // leading " › " once every slash becomes a separator.
        let abbreviated = (path as NSString).abbreviatingWithTildeInPath
        let withoutLeadingSlash = abbreviated.hasPrefix("/") ? String(abbreviated.dropFirst()) : abbreviated
        return withoutLeadingSlash.replacingOccurrences(of: "/", with: " › ")
    }
}

struct LauncherPreview: View {
    let result: LauncherResult?
    let store: ClipStore
    let query: String
    var onOpen: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var text: String?
    @State private var image: NSImage?
    @State private var code: NSAttributedString?
    @State private var loading = true
    @State private var loadedID: String?
    @State private var error: String?
    @State private var fileState: FileSearchInfo.Availability?
    @State private var filePreviewContent: FilePreviewContent?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            self.metadata
        }
        .padding(20)
        .background(.background.opacity(0.35))
        .task(id: self.result?.id) { await self.load() }
        .onChange(of: self.colorScheme) {
            if self.code != nil, let text { self.code = CodeHighlighter.highlight(text, dark: self.colorScheme == .dark) }
        }
    }

    @ViewBuilder private var content: some View {
        if self.loading || self.loadedID != self.result?.id {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text(error))
        } else if let result {
            switch result {
            case let .file(_, url, info):
                if self.fileState == .cloud || self.fileState == .downloading {
                    VStack(spacing: 14) {
                        Image(systemName: "icloud.and.arrow.down").font(.system(size: 38)).foregroundStyle(.secondary)
                        Text("Stored in \(info.location ?? "the cloud")").font(.headline)
                        Text("Download this file to open it. Browsing results keeps it in the cloud.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Download & Open", action: self.onOpen)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if self.fileState == .unavailable {
                    ContentUnavailableView("File unavailable", systemImage: "exclamationmark.icloud", description: Text("It may have moved, or its location may be offline. Rebuild the index in Settings → Files."))
                } else if self.fileState == .local {
                    if let filePreviewContent {
                        FilePreviewView(content: filePreviewContent)
                    } else {
                        NativeFilePreview(url: url)
                    }
                } else {
                    ProgressView()
                }
            case .clip, .snippet, .calculation, .webSearch:
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let code {
                    CodeTextView(attributed: code)
                } else {
                    ScrollView {
                        SearchHighlightedText(text: self.text ?? "", query: self.query)
                            .font(.system(size: 14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            default:
                ContentUnavailableView("Ready to open", systemImage: "arrow.up.forward.app", description: Text("Press Return to run the selected action."))
            }
        } else {
            ContentUnavailableView("Select a result", systemImage: "sidebar.right", description: Text("Its contents and source will appear here."))
        }
    }

    @ViewBuilder private var metadata: some View {
        if case let .clip(item) = self.result {
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                LabeledContent("Source", value: item.sourceAppName ?? "Unknown app")
                LabeledContent("Copied", value: item.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Type", value: item.kind.displayName)
                if let source = item.sourceURL, let url = URL(string: source) {
                    Link(destination: url) {
                        Label(item.sourceTitle ?? "Open source page", systemImage: "arrow.up.right.square").lineLimit(1)
                    }
                }
                if let detail = item.metadataFooter { Text(detail).foregroundStyle(.secondary) }
            }.font(.caption)
        } else if case let .file(name, url, info) = self.result {
            Divider()
            Text(name).font(.headline).lineLimit(2)
            Text(FileBreadcrumb.label(url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let date = info.modifiedAt { Text("Modified \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func load() async {
        self.text = nil; self.image = nil; self.code = nil; self.error = nil; self.fileState = nil; self.filePreviewContent = nil
        self.loading = true
        defer { if !Task.isCancelled { self.loadedID = self.result?.id; self.loading = false } }
        do {
            switch self.result {
            case let .clip(item):
                guard !item.isSecret else { self.error = "Protected clipboard item"; return }
                switch item.kind {
                case .image:
                    guard let representation = try await self.store.representations(for: item.id).first(where: { $0.uti == WellKnownUTI.png }) else { self.error = "Image data is missing."; return }
                    let data = try await self.store.payload(for: representation)
                    guard !Task.isCancelled else { return }
                    self.image = ItemCardView.thumbnail(from: data, maxPixel: 1400)
                case .file:
                    let paths = try await self.store.filePaths(for: item.id)
                    guard !Task.isCancelled else { return }
                    self.text = paths.joined(separator: "\n")
                default:
                    let text = try await self.store.plainText(for: item.id) ?? item.previewText ?? ""
                    guard !Task.isCancelled else { return }
                    self.text = text
                    if item.category == "code" || CodeHighlighter.looksLikeCode(text) {
                        self.code = CodeHighlighter.highlight(text, dark: self.colorScheme == .dark)
                    }
                }
            case let .file(_, url, _):
                let state = await Task.detached(priority: .utility) { FileAvailability.status(at: url) }.value
                guard !Task.isCancelled else { return }
                self.fileState = state
                if state == .local, FilePreviewEligibility.supports(url) {
                    self.filePreviewContent = await Task.detached(priority: .utility) {
                        try? FilePreviewLoader.load(url)
                    }.value
                }
            case let .snippet(item): self.text = item.body
            case let .calculation(input, display): self.text = "\(input) = \(display)"
            case let .webSearch(query, _): self.text = query
            default: break
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn’t load this item. Select it again to retry."
        }
    }
}

/// Only mounted after the metadata-only availability check. A dataless URL
/// must never be handed to Quick Look merely because its row is selected.
private struct NativeFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context _: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)
    }

    func updateNSView(_ view: QLPreviewView, context _: Context) {
        if (view.previewItem as? NSURL) != self.url as NSURL { view.previewItem = self.url as NSURL }
    }
}
