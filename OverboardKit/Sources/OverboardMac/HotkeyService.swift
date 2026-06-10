import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    /// Summons/dismisses the drawer. Carbon hotkey under the hood — no
    /// Accessibility permission needed.
    static let toggleDrawer = Self("toggleDrawer", default: .init(.v, modifiers: [.command, .shift]))
}

/// Thin wrapper so only OverboardMac imports KeyboardShortcuts.
@MainActor
public enum HotkeyService {
    public static func onToggleDrawer(_ handler: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .toggleDrawer, action: handler)
    }
}
