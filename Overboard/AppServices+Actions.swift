import AppKit
import OverboardCore
import OverboardMac
import OverboardUI

/// Shared copy/paste helpers that `ClipAction` side effects, the overlay and
/// launcher callbacks, and the App Intents (via `copyString`) all go through.
extension AppServices {
    /// Runs one action's side effects against the current selection.
    func runAction(_ action: ClipAction, on items: [ClipItem], target: NSRunningApplication?) async {
        await self.actions.run(action, on: items, target: target)
    }

    /// Marker-tagged copy + HUD. Internal (not private) so the App Intents in
    /// Intents/ can reuse the same copy path.
    func copyString(_ text: String, hud: String) {
        self.actions.copyString(text, hud: hud)
    }

    func pasteString(_ text: String, into target: NSRunningApplication?) {
        self.actions.pasteString(text, into: target)
    }

    /// Shared paste path: applies per-app plain-text rules, falls back to
    /// copy-only + HUD when Accessibility isn't granted.
    func pasteItem(
        _ item: ClipItem,
        mode: PasteMode,
        into target: NSRunningApplication?,
        onPasted: (@MainActor () -> Void)? = nil,
        onCompletion: (@MainActor (PastebackService.Outcome) -> Void)? = nil
    ) {
        Task {
            var effectiveMode = mode
            if effectiveMode == .full,
               item.kind == .text || item.kind == .link,
               let bundleID = target?.bundleIdentifier,
               Preferences.currentPlainTextApps().contains(bundleID)
            {
                effectiveMode = .plainText
            }
            let restore = Defaults[.restoreClipboard]
            let outcome = await self.pasteback.paste(
                item, into: target, restoreClipboard: restore, mode: effectiveMode
            )
            switch outcome {
            case .dispatched:
                onPasted?()
            case .copied:
                HUDController.shared.flash(PermissionService.copyOnlyPasteMessage())
                PermissionService.promptIfNeeded()
            case .cancelled:
                break
            case .failed:
                HUDController.shared.flash("Couldn't paste this item")
            }
            onCompletion?(outcome)
        }
    }
}
