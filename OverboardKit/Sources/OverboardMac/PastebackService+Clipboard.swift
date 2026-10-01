import AppKit

extension PastebackService {
    func owns(_ session: ClipboardSession) -> Bool {
        self.pasteboard.changeCount == session.changeCount
            && self.pasteboard.pasteboardItems?.first?.data(forType: ClipboardMonitor.markerType) == session.token
    }

    func restoreOwnedClipboard() {
        guard let session = self.clipboardSession else { return }
        if let backup = session.backup, self.owns(session) {
            self.restore(backup)
        }
        self.clipboardSession = nil
    }

    private func awaitPasteConsumed(_ probe: PasteConsumptionProbe) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < self.consumptionTimeout {
            try Task.checkCancellation()
            if probe.wasRead, ContinuousClock.now - start >= .milliseconds(250) {
                break
            }
            try await self.sleep(.milliseconds(50))
        }
        try await self.sleep(.milliseconds(150))
        try Task.checkCancellation()
    }

    func backupPasteboard() -> Backup {
        (self.pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    private func restore(_ backup: Backup) {
        let restored = backup.map { flavors in
            let item = NSPasteboardItem()
            for (type, data) in flavors {
                item.setData(data, forType: type)
            }
            item.setData(Data(), forType: ClipboardMonitor.markerType)
            return item
        }
        let clearedCount = self.pasteboard.clearContents()
        if !restored.isEmpty, self.pasteboard.changeCount == clearedCount {
            self.pasteboard.writeObjects(restored)
        }
    }

    func recoverFailedPublication(
        _ backup: Backup, clearedCount: Int, token: Data, probe: PasteConsumptionProbe
    ) {
        self.clipboardSession = nil
        let failedSession = ClipboardSession(
            token: token, changeCount: self.pasteboard.changeCount, backup: nil, probe: probe
        )
        if self.pasteboard.changeCount == clearedCount || self.owns(failedSession) {
            self.restore(backup)
        }
        self.operationID = nil
        self.operationTask = nil
    }

    func scheduleRestoration(probe: PasteConsumptionProbe, operation: Operation) {
        self.restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.awaitPasteConsumed(probe)
                guard self.isCurrent(operation) else { return }
                self.restoreOwnedClipboard()
            } catch {}
        }
    }
}
