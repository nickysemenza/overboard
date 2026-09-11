import AppIntents
import OverboardCore

/// Puts the most recent non-secret clip back on the pasteboard, so Shortcuts
/// and Siri can re-copy the last thing Overboard captured. Runs in the app
/// process (there's no extension target) via `AppServices.shared`.
struct CopyLatestClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Latest Clip"
    static let description = IntentDescription(
        "Copies your most recent Overboard clipboard item back to the clipboard."
    )
    /// The app is `LSUIElement` — running this shouldn't bring it to the
    /// foreground.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let services = AppServices.shared
        // `recent` is the same frecency-ordered listing the drawer shows;
        // secrets are skipped so a credential never reaches Shortcuts/Siri.
        let items = try await services.store.recent(limit: 20)
        guard let item = items.first(where: { !$0.isSecret }) else {
            return .result(value: "")
        }

        // Reuse the exact copy path the launcher's ⌘↩ uses, so the clipboard
        // monitor's marker/skip logic is respected and the item's use count
        // is bumped consistently.
        try await services.pasteback.copy(item)
        let text = await (try? services.store.plainText(for: item.id)) ?? ""
        return .result(value: text)
    }
}
