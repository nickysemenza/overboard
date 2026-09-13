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
    case downloadAndOpen
    case preview
    case pin
    case unpin
    case openSource

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
        case .downloadAndOpen: "Download & Open"
        case .preview: "Preview"
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .openSource: "Open Source Page"
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
        case .downloadAndOpen: "icloud.and.arrow.down"
        case .preview: "eye"
        case .pin, .unpin: "pin"
        case .openSource: "globe"
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
            self.appActions(context: context)
        case let .clip(item):
            self.clipActions(for: item)
        case let .file(_, _, info):
            [info.availability == .cloud ? .downloadAndOpen : .open, .revealInFinder, .copyPath, .preview]
        default:
            // Every other result's action list is a static function of the
            // case alone — split out so this switch's data-dependent cases
            // (app/clip/file, above) don't share a complexity budget with them.
            self.staticActions(for: result)
        }
    }

    /// ↩ open/switch, ⌘↩ reveal, ⌥↩ copy path; quit only when running.
    private static func appActions(context: LauncherActionContext) -> [LauncherAction] {
        var actions: [LauncherAction] = [
            context.isAppRunning ? .switchTo : .open,
            .revealInFinder,
            .copyPath,
        ]
        if context.isAppRunning {
            actions.append(.quitApp)
        }
        return actions
    }

    /// ↩ paste, ⌘↩ copy, ⌥↩ paste plain; link clips add Open Link.
    private static func clipActions(for item: ClipItem) -> [LauncherAction] {
        var actions: [LauncherAction] = [.paste, .copy, .pastePlain]
        if item.kind == .link {
            actions.append(.openLink)
        }
        actions += [.preview, item.isPinned ? .unpin : .pin]
        if item.sourceURL != nil {
            actions.append(.openSource)
        }
        return actions
    }

    /// Action lists for results whose actions depend only on which case they
    /// are, never on associated data (unlike app/clip/file, handled above).
    private static func staticActions(for result: LauncherResult) -> [LauncherAction] {
        switch result {
        case .snippet:
            // ↩ paste, ⌘↩ copy (⌥↩ is a no-op alias of ↩ for snippets).
            [.paste, .copy]
        case .calculation:
            // ↩ copy, ⌘↩ paste.
            [.copy, .paste]
        case .webSearch:
            [.search]
        case .systemSetting:
            [.openSetting]
        case .command:
            [.runCommand]
        case .recentSearch:
            [.rerunSearch, .removeRecent]
        case .nowPlaying:
            // ↩ copy link, ⌘↩ open Spotify.
            [.copyLink, .openInSpotify]
        case .askAI:
            // ↩ run + paste the result, ⌘↩ run + copy it.
            [.paste, .copy]
        case .app, .clip, .file:
            // Unreachable: `actions(for:context:)` handles these itself.
            []
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
