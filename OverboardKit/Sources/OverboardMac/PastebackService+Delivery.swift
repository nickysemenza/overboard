import AppKit
import OverboardCore

private struct ClipboardDelivery {
    let items: [NSPasteboardItem]
    let itemID: String?
    let target: NSRunningApplication?
    let restoreClipboard: Bool
    let copyOnly: Bool
}

extension PastebackService {
    public func paste(
        _ item: ClipItem,
        into target: NSRunningApplication?,
        restoreClipboard: Bool,
        mode: PasteMode = .full
    ) async -> Outcome {
        let operation = self.beginOperation()
        return await self.runOperation(operation) {
            do {
                let items = try await self.buildPasteboardItems(for: item, mode: mode)
                return await self.publish(ClipboardDelivery(
                    items: items, itemID: item.id, target: target,
                    restoreClipboard: restoreClipboard, copyOnly: false
                ), operation: operation)
            } catch {
                return self.finishFailure(operation, error: error)
            }
        }
    }

    @discardableResult
    public func copy(_ item: ClipItem) async -> Outcome {
        let operation = self.beginOperation()
        return await self.runOperation(operation) {
            do {
                let items = try await self.buildPasteboardItems(for: item, mode: .full)
                return await self.publish(ClipboardDelivery(
                    items: items, itemID: item.id, target: nil,
                    restoreClipboard: false, copyOnly: true
                ), operation: operation)
            } catch {
                return self.finishFailure(operation, error: error)
            }
        }
    }

    public func pasteText(
        _ text: String,
        into target: NSRunningApplication?,
        restoreClipboard: Bool
    ) async -> Outcome {
        await self.publishText(text, into: target, restoreClipboard: restoreClipboard, copyOnly: false)
    }

    @discardableResult
    public func copyText(_ text: String) async -> Outcome {
        await self.publishText(text, into: nil, restoreClipboard: false, copyOnly: true)
    }

    private func publishText(
        _ text: String,
        into target: NSRunningApplication?,
        restoreClipboard: Bool,
        copyOnly: Bool
    ) async -> Outcome {
        let operation = self.beginOperation()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: ClipboardMonitor.markerType)
        return await self.runOperation(operation) {
            await self.publish(ClipboardDelivery(
                items: [item], itemID: nil, target: target,
                restoreClipboard: restoreClipboard, copyOnly: copyOnly
            ), operation: operation)
        }
    }

    private func publish(_ delivery: ClipboardDelivery, operation: Operation) async -> Outcome {
        do {
            try await self.preparePublication(operation)
            let backup = try self.restorationBackup(for: delivery, operation: operation)
            guard let session = try self.publishClipboard(delivery, operation: operation, backup: backup)
            else { return .failed }
            await self.markPublishedItemUsed(delivery.itemID)
            return try await self.deliverPublishedClipboard(delivery, operation: operation, session: session)
        } catch {
            return self.finishFailure(operation, error: error)
        }
    }

    private func preparePublication(_ operation: Operation) async throws {
        guard self.isCurrent(operation) else { throw CancellationError() }
        try await self.beforePublication?()
        guard self.isCurrent(operation), self.pasteboard.changeCount == operation.changeCount else {
            throw CancellationError()
        }
    }

    private func restorationBackup(for delivery: ClipboardDelivery, operation: Operation) throws -> Backup? {
        let backup: Backup? = if delivery.restoreClipboard, let previous = self.clipboardSession, self.owns(previous),
                                 let original = previous.backup
        {
            original
        } else {
            delivery.restoreClipboard ? self.backupPasteboard() : nil
        }
        guard self.isCurrent(operation), self.pasteboard.changeCount == operation.changeCount else {
            throw CancellationError()
        }
        return backup
    }

    private func publishClipboard(
        _ delivery: ClipboardDelivery, operation: Operation, backup: Backup?
    ) throws -> ClipboardSession? {
        let token = Data(operation.id.uuidString.utf8)
        let (probed, probe) = Self.probed(delivery.items, marker: token)
        let rollbackBackup = backup ?? self.backupPasteboard()
        guard self.pasteboard.changeCount == operation.changeCount else { throw CancellationError() }
        let publication = delivery.copyOnly ? delivery.items : probed
        if delivery.copyOnly {
            publication.first?.setData(token, forType: ClipboardMonitor.markerType)
        }
        let clearedCount = self.pasteboard.clearContents()
        guard self.pasteboard.changeCount == clearedCount else { throw CancellationError() }
        guard self.writeObjects(publication) else {
            self.recoverFailedPublication(rollbackBackup, clearedCount: clearedCount, token: token, probe: probe)
            return nil
        }
        let session = ClipboardSession(
            token: token, changeCount: self.pasteboard.changeCount, backup: backup, probe: probe
        )
        self.clipboardSession = session
        self.activeProbe = delivery.copyOnly ? nil : probe
        guard self.owns(session) else { throw CancellationError() }
        return session
    }

    private func markPublishedItemUsed(_ itemID: String?) async {
        guard let itemID else { return }
        do {
            try await self.store.markUsed(id: itemID)
        } catch {
            self.logger.error("Published clipboard item, but usage update failed")
        }
    }

    private func deliverPublishedClipboard(
        _ delivery: ClipboardDelivery, operation: Operation, session: ClipboardSession
    ) async throws -> Outcome {
        guard self.isCurrent(operation), self.owns(session) else { throw CancellationError() }
        guard !delivery.copyOnly, self.isTrusted() else {
            self.clipboardSession = ClipboardSession(
                token: session.token, changeCount: session.changeCount, backup: nil, probe: session.probe
            )
            return .copied
        }
        guard self.activate(delivery.target) else {
            self.cancel()
            return .failed
        }
        try await self.sleep(.milliseconds(90))
        guard self.isCurrent(operation), self.owns(session) else { throw CancellationError() }
        guard self.isTargetActive(delivery.target), self.dispatch() else {
            self.cancel()
            return .failed
        }
        if session.backup != nil {
            self.scheduleRestoration(probe: session.probe, operation: operation)
        }
        return .dispatched
    }
}
