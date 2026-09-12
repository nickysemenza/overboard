import AppKit
import OverboardFilePreview
import QuickLookUI
import SwiftUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let previewContainer = NSView()

    override func loadView() {
        self.view = self.previewContainer
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let result = Result { try FilePreviewLoader.load(url) }
        switch result {
        case let .success(content):
            self.install(NSHostingView(rootView: FilePreviewView(content: content)))
        case let .failure(error):
            self.install(NSHostingView(rootView: PreviewUnavailableView(message: error.localizedDescription)))
        }
    }

    private func install(_ preview: NSView) {
        self.previewContainer.subviews.forEach { $0.removeFromSuperview() }
        preview.translatesAutoresizingMaskIntoConstraints = false
        self.previewContainer.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: self.previewContainer.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: self.previewContainer.trailingAnchor),
            preview.topAnchor.constraint(equalTo: self.previewContainer.topAnchor),
            preview.bottomAnchor.constraint(equalTo: self.previewContainer.bottomAnchor),
        ])
    }
}

private struct PreviewUnavailableView: View {
    let message: String

    var body: some View {
        ContentUnavailableView("Preview unavailable", systemImage: "doc.text", description: Text(self.message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
