import AppKit
import Foundation
import OverboardCore

/// Executes the side effects `ClipAction` describes. `ClipAction.run` is pure —
/// it returns an `ActionEffect` and touches nothing — and this is the other
/// half: the pasteboard writes, `NSWorkspace` opens, and file writes that
/// effect implies, plus the payload prefetch the pure half needs.
///
/// Everything outside AppKit is injected: the HUD is a `flash` closure (the HUD
/// lives a layer up, in OverboardUI), the paste stack is a closure for the same
/// reason, and Downloads is a closure so a test can point a save at a temp
/// directory.
public final class ClipActionExecutor {
    private let store: ClipStore
    private let pasteback: PastebackService
    private let flash: @MainActor (String) -> Void
    private let addToStack: @MainActor ([ClipItem]) -> Void
    private let downloadsDirectory: @MainActor () -> URL?

    public init(
        store: ClipStore,
        pasteback: PastebackService,
        flash: @escaping @MainActor (String) -> Void,
        addToStack: @escaping @MainActor ([ClipItem]) -> Void,
        downloadsDirectory: @escaping @MainActor () -> URL? = {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
    ) {
        self.store = store
        self.pasteback = pasteback
        self.flash = flash
        self.addToStack = addToStack
        self.downloadsDirectory = downloadsDirectory
    }

    /// Prefetches payloads, runs the pure action, then executes its effect.
    public func run(_ action: ClipAction, on items: [ClipItem], target: NSRunningApplication?) async {
        var inputs: [ActionInput] = []
        for item in items {
            let text = try? await self.store.plainText(for: item.id)
            var fileURLs: [URL] = []
            if item.kind == .file,
               let rep = try? await self.store.representations(for: item.id)
               .first(where: { $0.uti == WellKnownUTI.fileURLs }),
               let data = try? await self.store.payload(for: rep),
               let strings = try? JSONDecoder().decode([String].self, from: data)
            {
                fileURLs = strings.compactMap(URL.init(string:))
            }
            inputs.append(ActionInput(item: item, plainText: text, fileURLs: fileURLs))
        }

        await self.execute(action.run(inputs), target: target)
    }

    /// Carries out one already-decided effect.
    public func execute(_ effect: ActionEffect, target: NSRunningApplication?) async {
        switch effect {
        case let .pasteText(text):
            self.pasteString(text, into: target)

        case let .copyText(text, hud):
            self.copyString(text, hud: hud)

        case let .openURLs(urls):
            for url in urls {
                NSWorkspace.shared.open(url)
            }

        case let .revealFiles(urls):
            NSWorkspace.shared.activateFileViewerSelecting(urls)

        case let .saveImage(itemID):
            await self.saveImageToDownloads(itemID: itemID)

        case let .openImage(itemID):
            await self.openImageInPreview(itemID: itemID)

        case let .addToStack(items):
            self.addToStack(items)
            self.flash("\(items.count) items on the stack — ⌥⌘V to paste")

        case let .showMessage(message):
            self.flash(message)
        }
    }

    /// Writes to the pasteboard with the monitor's marker type so the copy
    /// doesn't re-enter history, then flashes the HUD. Shared by the action
    /// effects, the launcher's copy callbacks, and the App Intents.
    public func copyString(_ text: String, hud: String) {
        let pbItem = NSPasteboardItem()
        pbItem.setString(text, forType: .string)
        pbItem.setData(Data(), forType: ClipboardMonitor.markerType)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([pbItem])
        self.flash(hud)
    }

    /// Pastes arbitrary text into the target app, falling back to copy-only
    /// plus a HUD (and an Accessibility prompt) when the paste can't be
    /// synthesized.
    public func pasteString(_ text: String, into target: NSRunningApplication?) {
        let restore = Defaults[.restoreClipboard]
        let outcome = self.pasteback.pasteText(text, into: target, restoreClipboard: restore)
        if outcome == .copiedOnly {
            self.flash(PermissionService.copyOnlyPasteMessage())
            PermissionService.promptIfNeeded()
        }
    }

    /// Writes the item's PNG payload into Downloads under a timestamped name.
    /// Returns the file it wrote, or nil if there was no image or the write
    /// failed (both already reported through the HUD).
    @discardableResult
    public func saveImageToDownloads(itemID: String) async -> URL? {
        guard let data = await self.pngPayload(for: itemID),
              let downloads = self.downloadsDirectory()
        else {
            self.flash("Couldn't save image")
            return nil
        }
        let stamp = Date()
            .formatted(.iso8601.year().month().day().timeSeparator(.omitted).time(includingFractionalSeconds: false))
        let url = downloads.appendingPathComponent("Overboard \(stamp).png")
        do {
            try data.write(to: url)
            self.flash("Saved to Downloads")
            return url
        } catch {
            self.flash("Couldn't save image")
            return nil
        }
    }

    private func openImageInPreview(itemID: String) async {
        guard let data = await self.pngPayload(for: itemID) else {
            self.flash("Couldn't open image")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Overboard-\(itemID).png")
        do {
            try data.write(to: url)
        } catch {
            self.flash("Couldn't open image")
            return
        }
        // Force Preview.app to match the action's label, falling back to the
        // system default PNG handler if it's somehow missing.
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            do {
                _ = try await NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: preview,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func pngPayload(for itemID: String) async -> Data? {
        guard let rep = try? await self.store.representations(for: itemID)
            .first(where: { $0.uti == WellKnownUTI.png }),
            let data = try? await self.store.payload(for: rep)
        else { return nil }
        return data
    }
}
