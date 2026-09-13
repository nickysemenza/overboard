import AppIntents

/// Shows Overboard's clipboard history drawer — the same panel the global
/// hotkey opens.
struct ShowDrawerIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Overboard Drawer"
    static let description = IntentDescription(
        "Opens Overboard's clipboard history drawer."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentDependencies.current.showDrawer()
        return .result()
    }
}
