import AppKit
import OverboardCore

/// Curated fake clipboard history for demo mode (`OVERBOARD_DEMO=1`), used by
/// scripts/demo-screenshots.sh. Items get staggered `capturedAt` stamps so the
/// drawer order is deterministic — the screenshot script navigates by index:
///   0 pinned note · 1 code · 2 link · 3 image · 4 JSON · 5 files · 6 color
///   · 7 secret · 8 prose · 9 markdown · 10 shell command
enum DemoSeed {
    /// Launcher file rows for demo mode — the real Spotlight provider would
    /// leak the developer's home folder into README screenshots. Paths are
    /// fake; LauncherRow falls back to file-type icons for missing files.
    struct LauncherFiles: LauncherProvider {
        private static let paths = [
            "/Users/demo/Notes/release-notes.md",
            "/Users/demo/Notes/release-checklist.md",
            "/Users/demo/Designs/overboard-icon.sketch",
            "/Users/demo/Decks/launch-review.key",
        ]

        func results(for query: String) async -> [LauncherResult] {
            Self.paths
                .map { URL(fileURLWithPath: $0) }
                .filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
                .map { .file(name: $0.lastPathComponent, url: $0) }
        }
    }

    static func populate(_ store: ClipStore) async {
        let now = Date()

        func text(
            _ string: String,
            bundleID: String,
            appName: String,
            age: TimeInterval
        ) -> PasteboardSnapshot {
            PasteboardSnapshot(
                reps: [.init(uti: WellKnownUTI.plainText, data: Data(string.utf8))],
                sourceBundleID: bundleID,
                sourceAppName: appName,
                capturedAt: now.addingTimeInterval(-age)
            )
        }

        do {
            // Index 1: code snippet — `category: "code"` drives the
            // mini-highlighted card and the syntax-highlighted preview.
            let code = try await store.ingest(text(
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
                bundleID: "com.apple.dt.Xcode", appName: "Xcode", age: 120
            ))
            if let code {
                try await store.attachEnrichment(itemID: code.id, title: "Debounced async stream", category: "code")
            }

            // Index 2: single-line URL → link card.
            _ = try await store.ingest(text(
                "https://developer.apple.com/documentation/swiftui/imagerenderer",
                bundleID: "com.apple.Safari", appName: "Safari", age: 300
            ))

            // Index 3: image card.
            _ = try await store.ingest(PasteboardSnapshot(
                reps: [.init(uti: WellKnownUTI.png, data: Self.gradientPNG(width: 640, height: 400))],
                sourceBundleID: "com.apple.Preview",
                sourceAppName: "Preview",
                capturedAt: now.addingTimeInterval(-420)
            ))

            // Index 4: JSON — the ⌘K palette shot lands here so rows like
            // "Pretty-Print JSON" make sense.
            _ = try await store.ingest(text(
                #"{"name":"overboard","version":"1.4.0","dependencies":{"grdb":"7.0.0","highlightr":"2.2.1"},"private":true}"#,
                bundleID: "com.apple.Terminal", appName: "Terminal", age: 540
            ))

            // Index 5: file card.
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

            // Index 6: color swatch card.
            let color = try NSKeyedArchiver.archivedData(
                withRootObject: NSColor.systemIndigo, requiringSecureCoding: true
            )
            _ = try await store.ingest(PasteboardSnapshot(
                reps: [.init(uti: WellKnownUTI.color, data: color)],
                sourceBundleID: nil,
                sourceAppName: "Digital Color Meter",
                capturedAt: now.addingTimeInterval(-780)
            ))

            // Index 7: AWS's canonical documentation example key — not a real
            // credential, but shaped so SecretDetector masks the card.
            _ = try await store.ingest(text(
                "AKIAIOSFODNN7EXAMPLE",
                bundleID: "com.apple.Terminal", appName: "Terminal", age: 900
            ))

            // Index 8: prose with AI title + summary (sparkles row).
            let prose = try await store.ingest(text(
                """
                Standup notes — Tuesday
                - Ship the drawer entrance animation behind a reduced-motion check
                - Migrate search to FTS5 trigram tokenizer, re-index on launch
                - Alex to write up paste-stack edge cases before Thursday
                - Decide on keeping color clips in history (lean yes)
                """,
                bundleID: "com.apple.Notes", appName: "Notes", age: 1020
            ))
            if let prose {
                try await store.attachEnrichment(
                    itemID: prose.id,
                    title: "Standup notes",
                    category: "list",
                    summary: "Action items from Tuesday's standup."
                )
            }

            // Index 9: markdown — MarkdownDetector renders this in the preview.
            _ = try await store.ingest(text(
                """
                ## Overboard 1.5

                **Highlights**

                - Markdown clips now render in the preview pane
                - Search keystrokes debounce through [swift-async-algorithms](https://github.com/apple/swift-async-algorithms)
                - Settings migrated to typed keys

                > Pinned clips survive history purges.
                """,
                bundleID: "com.apple.Notes", appName: "Notes", age: 1100
            ))

            // Index 10: plain shell command.
            _ = try await store.ingest(text(
                "xcodebuild -project Overboard.xcodeproj -scheme Overboard build",
                bundleID: "com.apple.Terminal", appName: "Terminal", age: 1140
            ))

            // Index 0: pinned items sort first regardless of age.
            if let pinned = try await store.ingest(text(
                "Overboard ⛵️ — everything you copy goes overboard, nothing is lost at sea.",
                bundleID: "com.apple.Notes", appName: "Notes", age: 1260
            )) {
                try await store.setPinned(id: pinned.id, true)
            }

            // Snippets, for the launcher-clips shot: "standup" matches the
            // template here AND the prose item above, showing both row kinds
            // with their source badges in one frame.
            try await store.saveSnippet(Snippet(
                title: "Standup template",
                body: "Yesterday:\nToday:\nBlockers:"
            ))
            try await store.saveSnippet(Snippet(
                title: "Bug report",
                body: "Steps to reproduce:\n1.\n\nExpected:\nActual:\nBuild: {date}"
            ))
        } catch {
            NSLog("DemoSeed failed: \(error)")
        }
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
