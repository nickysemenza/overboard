import AppKit
import OverboardCore

extension PastebackService {
    static func probed(
        _ items: [NSPasteboardItem], marker: Data = Data()
    ) -> ([NSPasteboardItem], PasteConsumptionProbe) {
        let probe = PasteConsumptionProbe()
        let rebuilt = items.map { original in
            let item = NSPasteboardItem()
            var payloads: [NSPasteboard.PasteboardType: Data] = [:]
            for type in original.types where type != ClipboardMonitor.markerType {
                if let data = original.data(forType: type) {
                    payloads[type] = data
                }
            }
            let types = original.types.filter { payloads[$0] != nil }
            if !types.isEmpty {
                item.setDataProvider(PasteItemProvider(payloads: payloads, probe: probe), forTypes: types)
            }
            item.setData(marker, forType: ClipboardMonitor.markerType)
            return item
        }
        return (rebuilt, probe)
    }

    func buildPasteboardItems(for item: ClipItem, mode: PasteMode) async throws -> [NSPasteboardItem] {
        let clips = try await self.store.materialize(itemIDs: [item.id])
        guard let clip = clips.first else { throw PayloadError.empty }
        let reps = clip.representations.filter { mode != .plainText || $0.representation.uti == WellKnownUTI.plainText }
        let groups = Dictionary(grouping: reps) { $0.representation.itemIndex ?? 0 }
        let items = try groups.keys.sorted().flatMap { index in
            try self.buildPasteboardItems(representations: groups[index] ?? [])
        }
        guard !items.isEmpty else { throw PayloadError.empty }
        items.first?.setData(Data(), forType: ClipboardMonitor.markerType)
        return items
    }

    private func buildPasteboardItems(representations reps: [MaterializedRepresentation]) throws -> [NSPasteboardItem] {
        var items: [NSPasteboardItem] = []
        if let fileRep = reps.first(where: { $0.representation.uti == WellKnownUTI.fileURLs }) {
            let urls = try JSONDecoder().decode([String].self, from: fileRep.payload)
            for url in urls {
                guard URL(string: url)?.isFileURL == true else { throw PayloadError.invalidFileURL }
                let item = NSPasteboardItem()
                item.setString(url, forType: .fileURL)
                items.append(item)
            }
        }
        let main = items.first ?? NSPasteboardItem()
        for rep in reps where rep.representation.uti != WellKnownUTI.fileURLs {
            guard let type = Self.pasteboardType(for: rep.representation.uti) else { continue }
            main.setData(rep.payload, forType: type)
        }
        guard !main.types.isEmpty else { throw PayloadError.empty }
        return items.isEmpty ? [main] : items
    }

    private enum PayloadError: Error {
        case empty
        case invalidFileURL
    }

    static func pasteboardType(for uti: String) -> NSPasteboard.PasteboardType? {
        switch uti {
        case WellKnownUTI.plainText: .string
        case WellKnownUTI.rtf: .rtf
        case WellKnownUTI.html: .html
        case WellKnownUTI.png: .png
        case WellKnownUTI.tiff: .tiff
        case WellKnownUTI.color: NSPasteboard.PasteboardType(WellKnownUTI.color)
        case WellKnownUTI.fileURLs: nil
        default: uti == ClipboardMonitor.markerType.rawValue ? nil : NSPasteboard.PasteboardType(uti)
        }
    }
}

final class PasteConsumptionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var read = false

    var wasRead: Bool {
        self.lock.withLock { self.read }
    }

    func recordRead() {
        self.lock.withLock { self.read = true }
    }
}

private final class PasteItemProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let payloads: [NSPasteboard.PasteboardType: Data]
    private let probe: PasteConsumptionProbe

    init(payloads: [NSPasteboard.PasteboardType: Data], probe: PasteConsumptionProbe) {
        self.payloads = payloads
        self.probe = probe
    }

    func pasteboard(
        _: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        if let data = self.payloads[type] {
            self.probe.recordRead()
            item.setData(data, forType: type)
        }
    }
}
