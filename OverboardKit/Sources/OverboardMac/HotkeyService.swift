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

    /// The recorded global shortcut for each summon action, formatted like
    /// "⌥Space" — nil when the user has cleared it. Exposed as plain strings
    /// (rather than the `KeyboardShortcuts.Name`/`Shortcut` types) so callers
    /// that only need to display the binding, like the menu-bar menu, don't
    /// need their own dependency on the KeyboardShortcuts package.
    public static var toggleLauncherShortcutDescription: String? {
        KeyboardShortcuts.getShortcut(for: .toggleLauncher)?.description
    }

    public static var toggleDrawerShortcutDescription: String? {
        KeyboardShortcuts.getShortcut(for: .toggleDrawer)?.description
    }

    public static var toggleEmojiPickerShortcutDescription: String? {
        KeyboardShortcuts.getShortcut(for: .toggleEmojiPicker)?.description
    }
}
