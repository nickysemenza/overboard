import OverboardCore
import SwiftUI

#if DEBUG
    #Preview("Row: Calculation") {
        LauncherRow(
            result: .calculation(input: "12*4", display: "48"),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: App") {
        LauncherRow(
            result: .app(name: "Demo App", url: URL(fileURLWithPath: "/Applications/OverboardDemo.app")),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Snippet") {
        LauncherRow(
            result: .snippet(Snippet(title: "Standup update", body: "Yesterday: shipped X.")),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Clip") {
        LauncherRow(
            result: .clip(Fixtures.item(preview: "deploy checklist")),
            store: Fixtures.previewStore(),
            isSelected: true,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: File") {
        LauncherRow(
            result: .file(name: "notes.md", url: URL(fileURLWithPath: "/tmp/overboard-missing/notes.md")),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Web search") {
        LauncherRow(
            result: .webSearch(
                query: "swiftui previews",
                url: URL(string: "https://www.google.com/search?q=swiftui+previews")!
            ),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: System setting") {
        LauncherRow(
            result: .systemSetting(
                name: "Displays",
                url: URL(string: "x-apple.systempreferences:com.apple.preference.displays")!
            ),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Command") {
        LauncherRow(
            result: .command(.stats, subtitle: "128 items"),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Recent search") {
        LauncherRow(
            result: .recentSearch(query: "deploy checklist"),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Now playing") {
        LauncherRow(
            result: .nowPlaying(
                NowPlayingTrack(
                    title: "Song Title",
                    artist: "The Artist",
                    trackID: "spotify:track:6rqhFgbbKwnb9MLmUQDhG6",
                    state: .playing
                )
            ),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Ask AI") {
        LauncherRow(
            result: .askAI(prompt: "Summarize this"),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }
#endif
