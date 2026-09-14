import Foundation

/// A macOS system action offered as a launcher row: lock, sleep, or restart.
/// Purely descriptive — the dlsym'd lock call and the AppleScript sleep/restart
/// commands live in OverboardMac's `SystemActionService`.
public enum SystemAction: String, Sendable, CaseIterable {
    case lockScreen, sleep, restart

    public var title: String {
        switch self {
        case .lockScreen: "Lock Screen"
        case .sleep: "Sleep"
        case .restart: "Restart"
        }
    }

    public var subtitle: String {
        switch self {
        case .lockScreen: "Lock the screen"
        case .sleep: "Put the Mac to sleep"
        case .restart: "Restart the Mac"
        }
    }

    /// Extra terms `SearchMatcher` should treat as matching this action, so
    /// e.g. "reboot" finds Restart even though it isn't in the title.
    public var keywords: String {
        switch self {
        case .lockScreen: "lock"
        case .sleep: "sleep suspend"
        case .restart: "restart reboot"
        }
    }

    public var symbolName: String {
        switch self {
        case .lockScreen: "lock.fill"
        case .sleep: "moon.zzz.fill"
        case .restart: "arrow.clockwise.circle.fill"
        }
    }
}
