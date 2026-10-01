import AppKit
import OverboardMac
import OverboardUI

/// Global hotkey wiring.
extension AppServices {
    func registerHotkeys() {
        HotkeyService.onToggleDrawer { [weak self] in
            guard let self, self.isStarted else { return }
            self.overlay.toggle()
        }

        HotkeyService.onToggleLauncher { [weak self] in
            guard let self, self.isStarted else { return }
            self.launcher.toggle()
        }

        HotkeyService.onToggleEmojiPicker { [weak self] in
            guard let self, self.isStarted else { return }
            self.emojiPicker.toggle()
        }

        HotkeyService.onPasteNextFromStack { [weak self] in
            guard let self, self.isStarted else { return }
            guard let reservation = self.stack.reserveNext() else {
                HUDController.shared
                    .flash(self.stack.count == 0 ? "Paste stack is empty" : "Stack delivery is in progress")
                return
            }
            self.pasteItem(
                reservation.item, mode: .full, into: NSWorkspace.shared.frontmostApplication,
                onCompletion: { [weak self] outcome in
                    guard let self else { return }
                    if outcome == .dispatched {
                        if self.stack.commit(reservation), self.stack.count > 0 {
                            HUDController.shared.flash("Dispatched from stack — \(self.stack.count) left")
                        }
                    } else {
                        self.stack.rollback(reservation)
                    }
                }
            )
        }
    }
}
