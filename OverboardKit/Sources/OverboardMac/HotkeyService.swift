import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    /// Summons/dismisses the drawer. Carbon hotkey under the hood — no
    /// Accessibility permission needed.
    static let toggleDrawer = Self("toggleDrawer", default: .init(.v, modifiers: [.command, .shift]))

    /// Pastes (and pops) the next item from the paste stack.
    static let pasteNextFromStack = Self("pasteNextFromStack", default: .init(.v, modifiers: [.command, .option]))

    /// Summons/dismisses the launcher bar. ⌥Space — ⌘Space belongs to Spotlight.
    static let toggleLauncher = Self("toggleLauncher", default: .init(.space, modifiers: [.option]))

    /// Summons/dismisses the emoji picker. ⌃⌘Space deliberately shadows the
    /// system Character Viewer (Raycast's convention) — the Carbon hotkey wins
    /// while Overboard is running, and the binding is re-recordable in Settings.
    static let toggleEmojiPicker = Self("toggleEmojiPicker", default: .init(.space, modifiers: [.control, .command]))
}

/// Thin wrapper so only OverboardMac imports KeyboardShortcuts.
@MainActor
public enum HotkeyService {
    public static func onToggleDrawer(_ handler: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .toggleDrawer, action: handler)
    }

    public static func onPasteNextFromStack(_ handler: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .pasteNextFromStack, action: handler)
    }

    public static func onToggleLauncher(_ handler: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .toggleLauncher, action: handler)
    }

    public static func onToggleEmojiPicker(_ handler: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .toggleEmojiPicker, action: handler)
    }
}
