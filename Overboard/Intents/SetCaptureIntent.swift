import AppIntents

/// Pauses or resumes Overboard's clipboard capture — the same toggle backing
/// the menu-bar item and the `:pause`/`:resume` launcher commands.
struct SetCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Clipboard Capture"
    static let description = IntentDescription(
        "Pauses or resumes Overboard's clipboard capture."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Paused")
    var paused: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set clipboard capture paused: \(\.$paused)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.setCapturePaused(self.paused)
        return .result()
    }
}
