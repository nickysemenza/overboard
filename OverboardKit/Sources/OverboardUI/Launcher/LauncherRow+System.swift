import OverboardCore
import SwiftUI

/// Icon/title/subtitle rendering for the system-action, audio-output,
/// quicklink, shell-command, and calendar-event row kinds — split out of
/// `LauncherRow`'s icon/title/subtitle switches purely to keep each under
/// SwiftLint's cyclomatic-complexity budget: those five kinds collapse into
/// one branch there, and this file re-switches to render each.
extension LauncherRow {
    @ViewBuilder static func systemKindIcon(for result: LauncherResult) -> some View {
        switch result {
        case let .systemAction(action):
            Image(systemName: action.symbolName).font(.title2).foregroundStyle(.gray)
        case .audioOutput:
            Image(systemName: "hifispeaker.fill").font(.title2).foregroundStyle(.gray)
        case .quicklink:
            Image(systemName: "link.circle.fill").font(.title2).foregroundStyle(.blue)
        case .shellCommand:
            Image(systemName: "terminal.fill").font(.title2).foregroundStyle(.teal)
        case .calendarEvent:
            Image(systemName: "calendar").font(.title2).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    static func systemKindTitle(for result: LauncherResult) -> String {
        switch result {
        case let .systemAction(action): action.title
        case let .audioOutput(device): String(localized: "Switch output to \(device.name)", bundle: .module)
        case let .quicklink(link, query, _): self.quicklinkTitle(link: link, query: query)
        case let .shellCommand(command): String(localized: "Run “\(command)” in Ghostty", bundle: .module)
        case let .calendarEvent(event): event.title
        default: ""
        }
    }

    private static func quicklinkTitle(link: Quicklink, query: String) -> String {
        if query.isEmpty {
            String(localized: "Open \(link.name)", bundle: .module)
        } else {
            String(localized: "Search \(link.name) for “\(query)”", bundle: .module)
        }
    }

    static func systemKindSubtitle(for result: LauncherResult) -> String {
        switch result {
        case let .systemAction(action): action.subtitle
        case let .audioOutput(device): device.isDefault ? "Current output" : "Audio output"
        case let .quicklink(_, _, url): url.host ?? url.absoluteString
        case .shellCommand: "Opens a new Ghostty window"
        case let .calendarEvent(event): UpcomingEventFormatter.subtitle(for: event, now: .now)
        default: ""
        }
    }
}
