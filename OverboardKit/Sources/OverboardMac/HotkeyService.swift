import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    /// Summons/dismisses the drawer. Carbon hotkey under the hood — no
    /// Accessibility permission needed.
    static let toggleDrawer = Self("toggleDrawer", default: .init(.v, modifiers: [.command, .shift]))

    /// Pastes (and pops) the next item from the paste stack.
    static let pasteNextFromStack = Self("pasteNextFromStack", default: .init(.v, modifiers: [.command, .option]))
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
}
