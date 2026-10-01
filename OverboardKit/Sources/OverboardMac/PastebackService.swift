import AppKit
import os
import OverboardCore

public final class PastebackService {
    public enum Outcome: Sendable, Equatable {
        case dispatched
        case copied
        case cancelled
        case failed

        public static var pasted: Self {
            .dispatched
        }

        public static var copiedOnly: Self {
            .copied
        }

        public var didPublish: Bool {
            switch self {
            case .dispatched, .copied: true
            case .cancelled, .failed: false
            }
        }
    }

    typealias Backup = [[(NSPasteboard.PasteboardType, Data)]]

    struct Operation {
        let id: UUID
        let changeCount: Int
    }

    struct ClipboardSession {
        let token: Data
        let changeCount: Int
        let backup: Backup?
        let probe: PasteConsumptionProbe
    }

    let store: ClipStore
    let pasteboard: NSPasteboard
    let isTrusted: () -> Bool
    let activate: (NSRunningApplication?) -> Bool
    let isTargetActive: (NSRunningApplication?) -> Bool
    let dispatch: () -> Bool
    let sleep: (Duration) async throws -> Void
    let writeObjects: ([NSPasteboardItem]) -> Bool
    let consumptionTimeout: Duration
    let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "pasteback")
    var operationID: UUID?
    var operationTask: Task<Outcome, Never>?
    var clipboardSession: ClipboardSession?
    var activeProbe: PasteConsumptionProbe?
    var restoreTask: Task<Void, Never>?

    public var beforePublication: (() async throws -> Void)?

    public convenience init(store: ClipStore) {
        self.init(
            store: store,
            pasteboard: .general,
            isTrusted: { PermissionService.isTrusted },
            activate: { $0?.activate() ?? false },
            isTargetActive: { target in
                guard let target, !target.isTerminated else { return false }
                return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
            },
            dispatch: Self.synthesizeCmdV
        )
    }

    init(
        store: ClipStore,
        pasteboard: NSPasteboard,
        isTrusted: @escaping () -> Bool = { false },
        activate: @escaping (NSRunningApplication?) -> Bool = { _ in true },
        isTargetActive: @escaping (NSRunningApplication?) -> Bool = { _ in true },
        dispatch: @escaping () -> Bool = { true },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        consumptionTimeout: Duration = .seconds(5),
        writeObjects: (([NSPasteboardItem]) -> Bool)? = nil
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.isTrusted = isTrusted
        self.activate = activate
        self.isTargetActive = isTargetActive
        self.dispatch = dispatch
        self.sleep = sleep
        self.consumptionTimeout = consumptionTimeout
        self.writeObjects = writeObjects ?? { pasteboard.writeObjects($0) }
    }

    public func drain() async {
        _ = await self.operationTask?.value
        await self.restoreTask?.value
    }

    public func cancel() {
        self.operationID = nil
        self.operationTask?.cancel()
        self.operationTask = nil
        self.restoreTask?.cancel()
        self.restoreTask = nil
        self.restoreOwnedClipboard()
    }

    func runOperation(
        _ operation: Operation,
        body: @escaping @MainActor () async -> Outcome
    ) async -> Outcome {
        let task = Task { @MainActor in await body() }
        self.operationTask = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if self.operationID == operation.id {
            self.operationTask = nil
        }
        return outcome
    }

    func beginOperation() -> Operation {
        self.operationTask?.cancel()
        self.operationTask = nil
        self.restoreTask?.cancel()
        self.restoreTask = nil
        if let session = self.clipboardSession, !self.owns(session) {
            self.clipboardSession = nil
        }
        let operation = Operation(id: UUID(), changeCount: self.pasteboard.changeCount)
        self.operationID = operation.id
        return operation
    }

    func isCurrent(_ operation: Operation) -> Bool {
        self.operationID == operation.id && !Task.isCancelled
    }

    func finishFailure(_ operation: Operation, error: any Error) -> Outcome {
        guard self.operationID == operation.id else { return .cancelled }
        let cancelled = error is CancellationError || Task.isCancelled
        self.cancel()
        if !cancelled {
            self.logger.error("Pasteback failed before dispatch")
        }
        return cancelled ? .cancelled : .failed
    }

    private static func synthesizeCmdV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
