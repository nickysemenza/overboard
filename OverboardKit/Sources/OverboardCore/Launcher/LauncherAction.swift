import Foundation

/// One thing the launcher can do to the selected result — the vocabulary
/// shared by the footer bar (which shows the primary action) and the ⌘K
/// palette (which lists every applicable action). Pure metadata; the app
/// layer owns the side effects.
public enum LauncherAction: String, Sendable, CaseIterable, Identifiable {
    case open
    case revealInFinder
    case copyPath
    case switchTo
    case quitApp
    case paste
    case copy
    case pastePlain
    case openLink
    case search
    case openSetting
    case runCommand
    case rerunSearch
    case removeRecent
    case copyLink
    case openInSpotify

    public var id: String {
        self.rawValue
    }

    public var label: String {
        switch self {
        case .open: "Open"
        case .revealInFinder: "Reveal in Finder"
        case .copyPath: "Copy Path"
        case .switchTo: "Switch to"
        case .quitApp: "Quit"
        case .paste: "Paste"
        case .copy: "Copy"
        case .pastePlain: "Paste as Plain Text"
        case .openLink: "Open Link in Browser"
        case .search: "Search"
        case .openSetting: "Open"
        case .runCommand: "Run"
        case .rerunSearch: "Search Again"
        case .removeRecent: "Remove from Recents"
        case .copyLink: "Copy Link"
        case .openInSpotify: "Open in Spotify"
        }
    }

    public var systemImage: String {
        switch self {
        case .open, .openSetting: "arrow.up.forward.app"
        case .revealInFinder: "folder"
        case .copyPath: "text.line.first.and.arrowtriangle.forward"
        case .switchTo: "rectangle.2.swap"
        case .quitApp: "xmark.circle"
        case .paste: "doc.on.clipboard"
        case .copy: "doc.on.doc"
        case .pastePlain: "textformat"
        case .openLink: "safari"
        case .search: "magnifyingglass"
        case .runCommand: "return"
        case .rerunSearch: "clock.arrow.circlepath"
        case .removeRecent: "trash"
        case .copyLink: "link"
        case .openInSpotify: "music.note"
        }
    }
}

/// Flags describing the selected result's live environment — currently only
/// whether a selected app is already running (so its primary action reads
/// "Switch to" and a Quit action is offered). Room for future signals.
public struct LauncherActionContext: Sendable {
    public var isAppRunning = false

    public init(isAppRunning: Bool = false) {
        self.isAppRunning = isAppRunning
    }
}

/// Maps a `LauncherResult` to its ordered action list. The first three entries
/// mirror `LauncherViewModel.commit(modifier:)` exactly — index 0 is ↩, 1 is
/// ⌘↩, 2 is ⌥↩ — so the footer's primary label and the palette's committed
/// actions stay in lockstep with the keyboard. Any entries past index 2 are
/// palette-only extras.
public enum LauncherActions {
    public static func actions(
        for result: LauncherResult,
        context: LauncherActionContext = LauncherActionContext()
    ) -> [LauncherAction] {
        switch result {
        case .app:
            // ↩ open/switch, ⌘↩ reveal, ⌥↩ copy path; quit only when running.
            var actions: [LauncherAction] = [
                context.isAppRunning ? .switchTo : .open,
                .revealInFinder,
                .copyPath,
            ]
            if context.isAppRunning { actions.append(.quitApp) }
            return actions
        case let .clip(item):
            // ↩ paste, ⌘↩ copy, ⌥↩ paste plain; link clips add Open Link.
            var actions: [LauncherAction] = [.paste, .copy, .pastePlain]
            if item.kind == .link { actions.append(.openLink) }
            return actions
        case .snippet:
            // ↩ paste, ⌘↩ copy (⌥↩ is a no-op alias of ↩ for snippets).
            return [.paste, .copy]
        case .file:
            return [.open, .revealInFinder, .copyPath]
        case .calculation:
            // ↩ copy, ⌘↩ paste.
            return [.copy, .paste]
        case .webSearch:
            return [.search]
        case .systemSetting:
            return [.openSetting]
        case .command:
            return [.runCommand]
        case .recentSearch:
            return [.rerunSearch, .removeRecent]
        case .nowPlaying:
            // ↩ copy link, ⌘↩ open Spotify.
            return [.copyLink, .openInSpotify]
        case .askAI:
            // ↩ run + paste the result, ⌘↩ run + copy it.
            return [.paste, .copy]
        }
    }

    /// The modifier glyph for a positional action: ↩ / ⌘↩ / ⌥↩ for the first
    /// three, nil (palette-only) for the rest.
    public static func hint(at index: Int) -> String? {
        switch index {
        case 0: "↩"
        case 1: "⌘↩"
        case 2: "⌥↩"
        default: nil
        }
    }
}
