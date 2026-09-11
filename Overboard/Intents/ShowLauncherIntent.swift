import AppIntents

/// Shows Overboard's launcher — the same panel the global hotkey opens.
struct ShowLauncherIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Overboard Launcher"
    static let description = IntentDescription(
        "Opens Overboard's command launcher."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.launcher.show()
        return .result()
    }
}
