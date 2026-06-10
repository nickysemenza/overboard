import AppKit
import os
import OverboardCore

/// Writes history items back to the pasteboard. M1.2: copy-only.
/// M1.4 adds CGEvent ⌘V synthesis into the target app and clipboard restore.
@MainActor
public final class PastebackService {
    private let store: ClipStore
    private let logger = Logger(subsystem: "com.nicky.overboard", category: "pasteback")

    public init(store: ClipStore) {
        self.store = store
    }

    /// Puts the item on the general pasteboard (with the internal marker type
    /// so the monitor doesn't re-capture it) and bumps its usage.
    public func copyToPasteboard(_ item: ClipItem) async throws {
        let reps = try await store.representations(for: item.id)

        var pbItems: [NSPasteboardItem] = []

        // File URLs need one pasteboard item per URL for Finder to accept them.
        if let fileRep = reps.first(where: { $0.uti == WellKnownUTI.fileURLs }) {
            let payload = try await store.payload(for: fileRep)
            let urlStrings = (try? JSONDecoder().decode([String].self, from: payload)) ?? []
            for urlString in urlStrings {
                let pbItem = NSPasteboardItem()
                pbItem.setString(urlString, forType: .fileURL)
                pbItems.append(pbItem)
            }
        }

        let main = pbItems.first ?? NSPasteboardItem()
        for rep in reps where rep.uti != WellKnownUTI.fileURLs {
            guard let type = Self.pasteboardType(for: rep.uti) else { continue }
            let payload = try await store.payload(for: rep)
            main.setData(payload, forType: type)
        }
        main.setData(Data(), forType: ClipboardMonitor.markerType)
        if pbItems.isEmpty { pbItems = [main] }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(pbItems)

        try await self.store.markUsed(id: item.id)
    }

    static func pasteboardType(for uti: String) -> NSPasteboard.PasteboardType? {
        switch uti {
        case WellKnownUTI.plainText: .string
        case WellKnownUTI.rtf: .rtf
        case WellKnownUTI.html: .html
        case WellKnownUTI.png: .png
        case WellKnownUTI.color: NSPasteboard.PasteboardType(WellKnownUTI.color)
        default: nil
        }
    }
}
