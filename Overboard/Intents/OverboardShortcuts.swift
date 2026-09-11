import AppIntents

/// Surfaces every Overboard intent to Shortcuts, Siri, and macOS 26 Spotlight
/// actions with a few natural phrases each.
struct OverboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CopyLatestClipIntent(),
            phrases: [
                "Copy my latest clip in \(.applicationName)",
                "Copy the last thing I copied in \(.applicationName)",
                "Get my most recent clipboard item from \(.applicationName)",
            ],
            shortTitle: "Copy Latest Clip",
            systemImageName: "doc.on.clipboard"
        )

        AppShortcut(
            intent: SearchClipboardIntent(),
            phrases: [
                "Search my clipboard history in \(.applicationName)",
                "Find something I copied in \(.applicationName)",
            ],
            shortTitle: "Search Clipboard",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: CopySnippetIntent(),
            phrases: [
                "Copy a snippet in \(.applicationName)",
                "Copy a saved snippet from \(.applicationName)",
            ],
            shortTitle: "Copy Snippet",
            systemImageName: "text.badge.plus"
        )

        AppShortcut(
            intent: SetCaptureIntent(),
            phrases: [
                "Pause clipboard capture in \(.applicationName)",
                "Turn clipboard capture on or off in \(.applicationName)",
                "Set capture paused in \(.applicationName)",
            ],
            shortTitle: "Set Capture",
            systemImageName: "pause.circle"
        )

        AppShortcut(
            intent: ShowDrawerIntent(),
            phrases: [
                "Show my clipboard drawer in \(.applicationName)",
                "Open the \(.applicationName) drawer",
            ],
            shortTitle: "Show Drawer",
            systemImageName: "tray"
        )

        AppShortcut(
            intent: ShowLauncherIntent(),
            phrases: [
                "Show the \(.applicationName) launcher",
                "Open \(.applicationName) launcher",
            ],
            shortTitle: "Show Launcher",
            systemImageName: "square.grid.2x2"
        )
    }
}
