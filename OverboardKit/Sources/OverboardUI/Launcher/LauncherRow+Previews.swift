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

    #Preview("Row: System action") {
        LauncherRow(
            result: .systemAction(.lockScreen),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Audio output") {
        LauncherRow(
            result: .audioOutput(AudioOutputDevice(id: 1, name: "AirPods Pro", isDefault: true)),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Quicklink") {
        LauncherRow(
            result: .quicklink(
                Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}"),
                query: "swift grdb",
                url: URL(string: "https://github.com/search?q=swift%20grdb")!
            ),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Shell command") {
        LauncherRow(
            result: .shellCommand("brew upgrade"),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Row: Calendar event") {
        LauncherRow(
            result: .calendarEvent(CalendarEvent(
                eventIdentifier: "abc123",
                title: "Design review",
                start: Date().addingTimeInterval(720),
                end: Date().addingTimeInterval(2400),
                url: URL(string: "https://meet.google.com/abc-defg-hij")
            )),
            store: Fixtures.previewStore(),
            isSelected: false,
            runningAppPaths: []
        )
        .padding()
        .frame(width: 400)
    }
#endif
