import AppKit
import OverboardCore

/// Curated fake clipboard history for demo mode (`OVERBOARD_DEMO=1`), used by
/// scripts/demo-screenshots.sh. Items get staggered `capturedAt` stamps so the
/// drawer order is deterministic — the screenshot script navigates by index:
///   0 pinned note · 1 code · 2 link · 3 image · 4 JSON · 5 files · 6 color
///   · 7 secret · 8 prose · 9 markdown · 10 shell command
enum DemoSeed {
    /// Launcher file rows for demo mode — the real filename index would
    /// leak the developer's home folder into README screenshots. Paths are
    /// fake; LauncherRow falls back to file-type icons for missing files.
    struct LauncherFiles: LauncherProvider {
        private static let paths = [
            "/Users/demo/Notes/release-notes.md",
            "/Users/demo/Notes/release-checklist.md",
            "/Users/demo/Designs/overboard-icon.sketch",
            "/Users/demo/Decks/launch-review.key",
            "/Users/demo/Documents/hello",
            "/Users/demo/Library/Mobile Documents/com~apple~CloudDocs/Wedding/2026 budget.xlsx",
            "/Users/demo/Documents/Projects/Client archive/2026/Planning and logistics/" +
                "Meeting notes/release-retrospective.md",
        ]

        func results(for query: String) async -> [LauncherResult] {
            Self.paths
                .map { URL(fileURLWithPath: $0) }
                .filter { query.isEmpty || SearchMatcher.match(
                    query: query,
                    title: $0.lastPathComponent,
                    context: $0.deletingLastPathComponent().path
                ) != nil }
                .map { .file(
                    name: $0.lastPathComponent,
                    url: $0,
                    info: FileSearchInfo(
                        availability: $0.path.contains("CloudDocs") ? .cloud : .local,
                        location: $0.path.contains("CloudDocs") ? "iCloud Drive" : "On this Mac"
                    )
                ) }
        }
    }

    static func populate(_ store: ClipStore) async {
        let now = Date()
        do {
            try await self.seedCode(store: store, now: now)
            try await self.seedLink(store: store, now: now)
            try await self.seedImage(store: store, now: now)
            try await self.seedJSON(store: store, now: now)
            try await self.seedFiles(store: store, now: now)
            try await self.seedColor(store: store, now: now)
            try await self.seedSecret(store: store, now: now)
            try await self.seedProse(store: store, now: now)
            try await self.seedMarkdown(store: store, now: now)
            try await self.seedShellCommand(store: store, now: now)
            try await self.seedPinnedWelcome(store: store, now: now)
            try await self.seedSnippets(store: store)
        } catch {
            NSLog("DemoSeed failed: \(error)")
        }
    }

    private static func text(
        _ string: String,
        bundleID: String,
        appName: String,
        age: TimeInterval,
        now: Date
    ) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(string.utf8))],
            sourceBundleID: bundleID,
            sourceAppName: appName,
            capturedAt: now.addingTimeInterval(-age)
        )
    }

    /// Index 1: code snippet — `category: "code"` drives the
    /// mini-highlighted card and the syntax-highlighted preview.
    private static func seedCode(store: ClipStore, now: Date) async throws {
        let code = try await store.ingest(self.text(
            """
            func debounce<T>(_ delay: Duration, _ values: AsyncStream<T>) -> AsyncStream<T> {
                AsyncStream { continuation in
                    let task = Task {
                        for await value in values {
                            try? await Task.sleep(for: delay)
                            continuation.yield(value)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
            """,
            bundleID: "com.apple.dt.Xcode", appName: "Xcode", age: 120, now: now
        ))
        if let code {
            try await store.attachEnrichment(itemID: code.id, title: "Debounced async stream", category: "code")
        }
    }

    /// Index 2: single-line URL → link card.
    private static func seedLink(store: ClipStore, now: Date) async throws {
        _ = try await store.ingest(self.text(
            "https://developer.apple.com/documentation/swiftui/imagerenderer",
            bundleID: "com.apple.Safari", appName: "Safari", age: 300, now: now
        ))
    }

    /// Index 3: image card.
    private static func seedImage(store: ClipStore, now: Date) async throws {
        _ = try await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: self.gradientPNG(width: 640, height: 400))],
            sourceBundleID: "com.apple.Preview",
            sourceAppName: "Preview",
            capturedAt: now.addingTimeInterval(-420)
        ))
    }

    /// Index 4: JSON — the ⌘K palette shot lands here so rows like
    /// "Pretty-Print JSON" make sense.
    private static func seedJSON(store: ClipStore, now: Date) async throws {
        _ = try await store.ingest(self.text(
            #"{"name":"overboard","version":"1.4.0","dependencies":{"grdb":"7.0.0","#
                + #""highlightr":"2.2.1"},"private":true}"#,
            bundleID: "com.apple.Terminal", appName: "Terminal", age: 540, now: now
        ))
    }

    /// Index 5: file card.
    private static func seedFiles(store: ClipStore, now: Date) async throws {
        let paths = ["/Users/demo/Designs/overboard-icon.sketch", "/Users/demo/Notes/release-notes.md"]
        let fileURLs = try JSONEncoder().encode(paths.map { URL(fileURLWithPath: $0).absoluteString })
        _ = try await store.ingest(PasteboardSnapshot(
            reps: [
                .init(uti: WellKnownUTI.fileURLs, data: fileURLs),
                .init(uti: WellKnownUTI.plainText, data: Data(paths.joined(separator: "\n").utf8)),
            ],
            sourceBundleID: "com.apple.finder",
            sourceAppName: "Finder",
            capturedAt: now.addingTimeInterval(-660)
        ))
    }

    /// Index 6: color swatch card.
    private static func seedColor(store: ClipStore, now: Date) async throws {
        let color = try NSKeyedArchiver.archivedData(
            withRootObject: NSColor.systemIndigo, requiringSecureCoding: true
        )
        _ = try await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.color, data: color)],
            sourceBundleID: nil,
            sourceAppName: "Digital Color Meter",
            capturedAt: now.addingTimeInterval(-780)
        ))
    }

    /// Index 7: AWS's canonical documentation example key — not a real
    /// credential, but shaped so SecretDetector masks the card.
    private static func seedSecret(store: ClipStore, now: Date) async throws {
        _ = try await store.ingest(self.text(
            "AKIAIOSFODNN7EXAMPLE",
            bundleID: "com.apple.Terminal", appName: "Terminal", age: 900, now: now
        ))
    }

    /// Index 8: prose with AI title + summary (sparkles row).
    private static func seedProse(store: ClipStore, now: Date) async throws {
        let prose = try await store.ingest(self.text(
            """
            Standup notes — Tuesday
            - Ship the drawer entrance animation behind a reduced-motion check
            - Migrate search to FTS5 trigram tokenizer, re-index on launch
            - Alex to write up paste-stack edge cases before Thursday
            - Decide on keeping color clips in history (lean yes)
            """,
            bundleID: "com.apple.Notes", appName: "Notes", age: 1020, now: now
        ))
        if let prose {
            try await store.attachEnrichment(
                itemID: prose.id,
                title: "Standup notes",
                category: "list",
                summary: "Action items from Tuesday's standup."
            )
        }
    }

    /// Index 9: markdown — MarkdownDetector renders this in the preview.
    private static func seedMarkdown(store: ClipStore, now: Date) async throws {
        _ = try await store.ingest(self.text(
            """
            ## Overboard 1.5

            **Highlights**

            - Markdown clips now render in the preview pane
            - Search keystrokes debounce through \
            [swift-async-algorithms](https://github.com/apple/swift-async-algorithms)
            - Settings migrated to typed keys

            > Pinned clips survive history purges.
            """,
            bundleID: "com.apple.Notes", appName: "Notes", age: 1100, now: now
        ))
    }

    /// Index 10: plain shell command.
    private static func seedShellCommand(store: ClipStore, now: Date) async throws {
        _ = try await store.ingest(self.text(
            "xcodebuild -project Overboard.xcodeproj -scheme Overboard build",
            bundleID: "com.apple.Terminal", appName: "Terminal", age: 1140, now: now
        ))
    }

    /// Index 0: pinned items sort first regardless of age.
    private static func seedPinnedWelcome(store: ClipStore, now: Date) async throws {
        if let pinned = try await store.ingest(self.text(
            "Overboard ⛵️ — everything you copy goes overboard, nothing is lost at sea.",
            bundleID: "com.apple.Notes", appName: "Notes", age: 1260, now: now
        )) {
            try await store.setPinned(id: pinned.id, true)
        }
    }

    /// Snippets, for the launcher-clips shot: "standup" matches the
    /// template here AND the prose item above, showing both row kinds
    /// with their source badges in one frame.
    private static func seedSnippets(store: ClipStore) async throws {
        try await store.saveSnippet(Snippet(
            title: "Standup template",
            body: "Yesterday:\nToday:\nBlockers:"
        ))
        try await store.saveSnippet(Snippet(
            title: "Bug report",
            body: "Steps to reproduce:\n1.\n\nExpected:\nActual:\nBuild: {date}"
        ))
    }

    /// A pleasant diagonal gradient stand-in for a screenshot/image clip.
    private static func gradientPNG(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let gradient = NSGradient(
                starting: NSColor(calibratedRed: 0.35, green: 0.40, blue: 0.95, alpha: 1),
                ending: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.85, alpha: 1)
            )
            gradient?.draw(in: rect, angle: 35)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
}
