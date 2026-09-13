import AppKit
import OverboardMac
import OverboardUI

/// Global hotkey wiring.
extension AppServices {
    func registerHotkeys() {
        HotkeyService.onToggleDrawer { [weak self] in
            self?.overlay.toggle()
        }

        HotkeyService.onToggleLauncher { [weak self] in
            self?.launcher.toggle()
        }

        HotkeyService.onToggleEmojiPicker { [weak self] in
            self?.emojiPicker.toggle()
        }

        HotkeyService.onPasteNextFromStack { [weak self] in
            guard let self else { return }
            guard let item = self.stack.popNext() else {
                HUDController.shared.flash("Paste stack is empty")
                return
            }
            let remaining = self.stack.count
            self.pasteItem(item, mode: .full, into: NSWorkspace.shared.frontmostApplication) {
                if remaining > 0 {
                    HUDController.shared.flash("Pasted from stack — \(remaining) left")
                }
            }
        }
    }
}
