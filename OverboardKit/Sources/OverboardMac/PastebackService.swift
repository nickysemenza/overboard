import AppKit
import os
import OverboardCore

/// Writes history items back to the pasteboard and synthesizes ⌘V into the
/// target app. Direct paste needs Accessibility; without it we fall back to
/// copy-only (the caller shows a "press ⌘V" HUD).
@MainActor
public final class PastebackService {
    public enum Outcome: Sendable {
        /// ⌘V was synthesized into the target app.
        case pasted
        /// No Accessibility permission — item is on the clipboard, user pastes manually.
        case copiedOnly
    }

    private let store: ClipStore
    private let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "pasteback")
    private var restoreTask: Task<Void, Never>?

    public init(store: ClipStore) {
        self.store = store
    }

    /// Full paste-back: optionally snapshot the current clipboard, write the
    /// item, re-activate the target, synthesize ⌘V, then restore the snapshot
    /// once the paste has landed.
    public func paste(
        _ item: ClipItem,
        into target: NSRunningApplication?,
        restoreClipboard: Bool,
        mode: PasteMode = .full
    ) async throws -> Outcome {
        let pbItems = try await buildPasteboardItems(for: item, mode: mode)
        try await self.store.markUsed(id: item.id)
        return self.writeAndPaste(pbItems, into: target, restoreClipboard: restoreClipboard)
    }

    /// Copy-only variant: writes the item's full representations to the
    /// pasteboard without synthesizing ⌘V (the launcher's ⌘↩).
    public func copy(_ item: ClipItem) async throws {
        // buildPasteboardItems already sets the monitor's marker type, so the
        // copy doesn't re-enter history.
        let pbItems = try await buildPasteboardItems(for: item, mode: .full)
        try await self.store.markUsed(id: item.id)
        self.restoreTask?.cancel()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(pbItems)
    }

    /// Pastes an arbitrary string (snippets, transforms) — plain text only.
    public func pasteText(
        _ text: String,
        into target: NSRunningApplication?,
        restoreClipboard: Bool
    ) -> Outcome {
        let pbItem = NSPasteboardItem()
        pbItem.setString(text, forType: .string)
        pbItem.setData(Data(), forType: ClipboardMonitor.markerType)
        return self.writeAndPaste([pbItem], into: target, restoreClipboard: restoreClipboard)
    }

    private func writeAndPaste(
        _ pbItems: [NSPasteboardItem],
        into target: NSRunningApplication?,
        restoreClipboard: Bool
    ) -> Outcome {
        self.restoreTask?.cancel()
        let backup = restoreClipboard ? Self.backupPasteboard() : nil

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(pbItems)

        guard PermissionService.isTrusted else { return .copiedOnly }

        let expectedChangeCount = pasteboard.changeCount

        self.restoreTask = Task { @MainActor in
            // Belt and braces: with a nonactivating panel the target never lost
            // frontmost status, but re-activate in case focus drifted.
            target?.activate()
            try? await Task.sleep(for: .milliseconds(90))
            Self.synthesizeCmdV()

            guard let backup else { return }
            // Give the target app time to consume the paste.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            // Only restore if nothing else wrote to the pasteboard in the
            // meantime — never clobber newer content.
            guard pasteboard.changeCount == expectedChangeCount else { return }
            Self.restore(backup)
        }
        return .pasted
    }

    // MARK: - Clipboard backup/restore

    /// All flavors of all items currently on the pasteboard.
    private static func backupPasteboard() -> [[(NSPasteboard.PasteboardType, Data)]]? {
        guard let items = NSPasteboard.general.pasteboardItems, !items.isEmpty else { return nil }
        let backup = items.map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
        return backup.contains(where: { !$0.isEmpty }) ? backup : nil
    }

    private static func restore(_ backup: [[(NSPasteboard.PasteboardType, Data)]]) {
        let restored = backup.map { flavors in
            let item = NSPasteboardItem()
            for (type, data) in flavors {
                item.setData(data, forType: type)
            }
            // Marked so the monitor doesn't re-capture the restore as a new copy.
            item.setData(Data(), forType: ClipboardMonitor.markerType)
            return item
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(restored)
    }

    // MARK: - Key synthesis

    private static func synthesizeCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Internal (not private) so tests can inspect the produced items — the UTI
    /// mapping, file-URL fan-out, and marker tagging — without writing to the
    /// shared system pasteboard.
    func buildPasteboardItems(
        for item: ClipItem,
        mode: PasteMode
    ) async throws -> [NSPasteboardItem] {
        var reps = try await store.representations(for: item.id)
        if mode == .plainText {
            reps = reps.filter { $0.uti == WellKnownUTI.plainText }
        }

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
        return pbItems
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
