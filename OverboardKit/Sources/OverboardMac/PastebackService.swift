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

    /// Every flavor of every item that was on the pasteboard before a paste.
    typealias Backup = [[(NSPasteboard.PasteboardType, Data)]]

    private let store: ClipStore
    private let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "pasteback")
    private var restoreTask: Task<Void, Never>?

    /// The clipboard we still owe the user, kept across a cancelled restore so a
    /// chain of pastes (the stack's ⌥⌘V) restores what they actually had rather
    /// than whatever the previous paste left behind.
    private var pendingBackup: Backup?

    /// Retained for as long as the probed items might sit on the pasteboard: if
    /// the provider deallocates first, a late paste gets nothing.
    private var activeProbe: PasteConsumptionProbe?

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
        // A deliberate copy supersedes any clipboard we owed the user.
        self.restoreTask?.cancel()
        self.pendingBackup = nil
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
        // Carry a still-owed backup forward instead of re-snapshotting: mid-chain
        // the pasteboard holds our own last write, not the user's clipboard.
        let backup: Backup? = restoreClipboard
            ? (self.pendingBackup ?? Self.backupPasteboard())
            : nil
        self.pendingBackup = backup

        let (probedItems, probe) = Self.probed(pbItems)
        self.activeProbe = probe

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(probedItems)

        guard PermissionService.isTrusted else {
            self.pendingBackup = nil
            return .copiedOnly
        }

        let expectedChangeCount = pasteboard.changeCount

        self.restoreTask = Task { @MainActor in
            // Belt and braces: with a nonactivating panel the target never lost
            // frontmost status, but re-activate in case focus drifted.
            target?.activate()
            try? await Task.sleep(for: .milliseconds(90))
            Self.synthesizeCmdV()

            guard let backup else {
                self.pendingBackup = nil
                return
            }
            guard await Self.awaitPasteConsumed(probe) else { return }
            // Only restore if nothing else wrote to the pasteboard in the
            // meantime — never clobber newer content.
            guard pasteboard.changeCount == expectedChangeCount else {
                self.pendingBackup = nil
                return
            }
            Self.restore(backup)
            self.pendingBackup = nil
        }
        return .pasted
    }

    // MARK: - Paste completion

    /// How long a read is ignored after ⌘V is posted. Universal Clipboard and
    /// pasteboard inspectors sample the general pasteboard on their own
    /// schedule, so the first read is not necessarily the paste.
    private static let consumptionFloor = Duration.milliseconds(250)
    /// Give up waiting and restore anyway — the paste may never have landed
    /// (wrong app focused, keystroke swallowed), and the user still wants their
    /// clipboard back.
    private static let consumptionTimeout = Duration.seconds(5)
    /// Apps pull flavors one at a time; let the rest arrive before swapping.
    private static let settleAfterRead = Duration.milliseconds(150)

    /// Waits until the target app has actually read the pasteboard. macOS has no
    /// "paste finished" notification, and `changeCount` only reveals *other
    /// writers* — it cannot say whether a paste was consumed. A lazy data
    /// provider can: the receiving app requesting our bytes is the paste. The
    /// old fixed 600 ms wait clobbered slow targets (Electron apps under load),
    /// which then pasted the restored clipboard instead of the chosen item.
    ///
    /// Returns false if cancelled by a newer paste.
    private static func awaitPasteConsumed(_ probe: PasteConsumptionProbe) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < self.consumptionTimeout {
            if probe.wasRead, ContinuousClock.now - start >= self.consumptionFloor {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled {
                return false
            }
        }
        try? await Task.sleep(for: self.settleAfterRead)
        return !Task.isCancelled
    }

    /// Rebuilds items so their content flavors are vended on demand, which is
    /// what makes the read observable. The marker stays eager — the monitor only
    /// checks `types`, and a provider call for it would be a false read signal.
    ///
    /// Internal (not private) so tests can verify the rebuild preserves flavors
    /// and bytes, without writing to the shared system pasteboard.
    static func probed(
        _ items: [NSPasteboardItem]
    ) -> ([NSPasteboardItem], PasteConsumptionProbe) {
        var payloads: [NSPasteboard.PasteboardType: Data] = [:]
        var contentTypes: [[NSPasteboard.PasteboardType]] = []

        for item in items {
            var types: [NSPasteboard.PasteboardType] = []
            for type in item.types where type != ClipboardMonitor.markerType {
                guard let data = item.data(forType: type) else { continue }
                payloads[type] = data
                types.append(type)
            }
            contentTypes.append(types)
        }

        let probe = PasteConsumptionProbe(payloads: payloads)
        let rebuilt = contentTypes.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            if !types.isEmpty {
                item.setDataProvider(probe, forTypes: types)
            }
            item.setData(Data(), forType: ClipboardMonitor.markerType)
            return item
        }
        return (rebuilt, probe)
    }

    // MARK: - Clipboard backup/restore

    /// All flavors of all items currently on the pasteboard.
    private static func backupPasteboard() -> Backup? {
        guard let items = NSPasteboard.general.pasteboardItems, !items.isEmpty else { return nil }
        let backup = items.map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
        return backup.contains(where: { !$0.isEmpty }) ? backup : nil
    }

    private static func restore(_ backup: Backup) {
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

/// Vends paste payloads on demand so the moment the target app reads them is
/// observable. Payloads are already in memory — the laziness buys the signal,
/// not the I/O. Callbacks arrive on whatever thread the receiving app asks
/// from, hence the lock.
final class PasteConsumptionProbe: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let payloads: [NSPasteboard.PasteboardType: Data]
    private let lock = NSLock()
    private var read = false

    var wasRead: Bool {
        self.lock.withLock { self.read }
    }

    init(payloads: [NSPasteboard.PasteboardType: Data]) {
        self.payloads = payloads
    }

    func pasteboard(
        _: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        self.lock.withLock { self.read = true }
        if let data = self.payloads[type] {
            item.setData(data, forType: type)
        }
    }
}
