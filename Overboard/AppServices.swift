import AppKit
import os
import OverboardCore
import OverboardMac

/// Composition root: owns the store, monitor, and (later) hotkey + overlay.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: ClipStore
    let monitor: ClipboardMonitor

    private var ingestTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.nicky.overboard", category: "app")

    private init() {
        do {
            let directory = try OverboardDatabase.defaultDirectory()
            let pool = try OverboardDatabase.open(at: directory)
            let blobs = try BlobStore(directory: directory.appendingPathComponent("blobs", isDirectory: true))
            self.store = ClipStore(dbWriter: pool, blobs: blobs)
        } catch {
            // Without a database there is no app; surface loudly in dev.
            fatalError("Failed to open Overboard database: \(error)")
        }
        self.monitor = ClipboardMonitor()
    }

    func start() {
        self.monitor.start()
        let store = store
        let snapshots = self.monitor.snapshots
        self.ingestTask = Task(priority: .utility) { [logger] in
            for await snapshot in snapshots {
                do {
                    try await store.ingest(snapshot)
                } catch {
                    logger.error("ingest failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
