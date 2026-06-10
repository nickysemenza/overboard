import AppKit
import os
import OverboardCore
import OverboardMac
import OverboardUI

/// Composition root: owns the store, monitor, overlay, hotkey, and paste-back.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: ClipStore
    let monitor: ClipboardMonitor
    let pasteback: PastebackService
    let overlay: OverlayController

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
        self.pasteback = PastebackService(store: self.store)
        self.overlay = OverlayController(store: self.store)
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

        self.overlay.onCommit = { [weak self] item, target in
            guard let self else { return }
            Task {
                do {
                    let restore = UserDefaults.standard.object(forKey: "restoreClipboardAfterPaste") as? Bool ?? true
                    let outcome = try await self.pasteback.paste(item, into: target, restoreClipboard: restore)
                    if outcome == .copiedOnly {
                        HUDController.shared.flash("Copied — press ⌘V to paste")
                        PermissionService.promptIfNeeded()
                    }
                } catch {
                    self.logger.error("paste failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        HotkeyService.onToggleDrawer { [weak self] in
            self?.overlay.toggle()
        }
    }
}
