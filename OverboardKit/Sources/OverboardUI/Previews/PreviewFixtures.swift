#if DEBUG
    import AppKit
    import ImageIO
    import OverboardCore
    import OverboardMac
    import SwiftUI
    import UniformTypeIdentifiers

    /// Deterministic fixtures shared by `#Preview` blocks and by
    /// `OverboardUISnapshotTests`: fixed dates, and bundle IDs that resolve to no
    /// installed app so AppIconCache yields the neutral header instead of
    /// machine-dependent app icons. DEBUG-only — never compiled into a release
    /// build.
    enum Fixtures {
        static let date = Date(timeIntervalSince1970: 1_700_000_000)

        static func item(
            kind: ItemKind = .text,
            preview: String,
            appName: String = "Demo Editor",
            isPinned: Bool = false,
            isSecret: Bool = false,
            aiTitle: String? = nil,
            category: String? = nil,
            aiSummary: String? = nil,
            charCount: Int? = nil,
            lineCount: Int? = nil,
            pixelWidth: Int? = nil,
            pixelHeight: Int? = nil,
            fileCount: Int? = nil,
            linkTitle: String? = nil,
            linkDescription: String? = nil,
            faviconData: Data? = nil,
            previewImageData: Data? = nil
        ) -> ClipItem {
            ClipItem(
                id: "fixture-\(preview.prefix(24))",
                contentHash: "fixture-hash",
                kind: kind,
                previewText: preview,
                sourceBundleID: "dev.example.editor",
                sourceAppName: appName,
                byteSize: preview.utf8.count,
                isPinned: isPinned,
                isSecret: isSecret,
                aiTitle: aiTitle,
                category: category,
                aiSummary: aiSummary,
                createdAt: self.date,
                lastUsedAt: self.date,
                updatedAt: self.date,
                charCount: charCount,
                lineCount: lineCount,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                fileCount: fileCount,
                linkTitle: linkTitle,
                linkDescription: linkDescription,
                faviconData: faviconData,
                previewImageData: previewImageData
            )
        }

        /// A tiny solid-color PNG, generated in-memory via ImageIO — no external
        /// fixture files, no AppKit drawing. Stands in for a fetched favicon /
        /// og:image in card snapshots and previews.
        static func solidPNG(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil
            )!
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return data as Data
        }

        static func store() throws -> ClipStore {
            let queue = try OverboardDatabase.openInMemory()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("overboard-fixtures-\(UUID().uuidString)", isDirectory: true)
            return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
        }

        static func textSnapshot(_ text: String) -> PasteboardSnapshot {
            PasteboardSnapshot(
                reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
                sourceBundleID: "dev.example.editor",
                sourceAppName: "Demo Editor",
                capturedAt: self.date
            )
        }

        // MARK: - Emoji picker

        /// A small fixed catalog of long-stable emoji (Unicode 6-era) — snapshotting
        /// or previewing the real 1,900-glyph dataset would tie the images to
        /// whichever Apple Color Emoji revision the rendering Mac has. Nonisolated
        /// so the view model's `@Sendable` catalog closure can call it.
        nonisolated static func emojiCatalog() -> EmojiCatalog {
            func emoji(_ character: String, _ name: String, _ category: EmojiCategory, keywords: [String] = []) -> Emoji {
                Emoji(character: character, name: name, keywords: keywords, category: category, version: 0.6)
            }
            return EmojiCatalog(all: [
                emoji("😀", "grinning face", .smileys, keywords: ["smile", "happy"]),
                emoji("😂", "face with tears of joy", .smileys, keywords: ["laugh"]),
                emoji("😍", "smiling face with heart-eyes", .smileys, keywords: ["love"]),
                emoji("🙃", "upside-down face", .smileys),
                emoji("😴", "sleeping face", .smileys, keywords: ["zzz"]),
                emoji("👍", "thumbs up", .people, keywords: ["approve", "yes"]),
                emoji("👋", "waving hand", .people, keywords: ["hello"]),
                emoji("💪", "flexed biceps", .people, keywords: ["strong"]),
                emoji("🐶", "dog face", .animals, keywords: ["puppy"]),
                emoji("🐱", "cat face", .animals, keywords: ["kitten"]),
                emoji("🌵", "cactus", .animals),
                emoji("🍕", "pizza", .food, keywords: ["slice"]),
                emoji("🍣", "sushi", .food),
                emoji("☕", "hot beverage", .food, keywords: ["coffee", "tea"]),
                emoji("🚀", "rocket", .travel, keywords: ["launch", "space"]),
                emoji("🔥", "fire", .travel, keywords: ["flame", "hot"]),
                emoji("⚽", "soccer ball", .activities, keywords: ["football"]),
                emoji("🎉", "party popper", .activities, keywords: ["celebrate"]),
                emoji("💡", "light bulb", .objects, keywords: ["idea"]),
                emoji("📎", "paperclip", .objects),
                emoji("❤️", "red heart", .symbols, keywords: ["love"]),
                emoji("✅", "check mark button", .symbols, keywords: ["done"]),
                emoji("🏁", "chequered flag", .flags, keywords: ["race"]),
                emoji("🏳️", "white flag", .flags, keywords: ["surrender"]),
            ])
        }

        /// Builds a ready-to-render `EmojiPickerViewModel` against `emojiCatalog()`.
        /// Pins the shared recents key so the machine's real picks can't leak into
        /// deterministic fixtures.
        @MainActor
        static func emojiPickerViewModel(recents: [String] = []) -> EmojiPickerViewModel {
            Defaults[.emojiRecents] = recents
            let viewModel = EmojiPickerViewModel(catalog: { Fixtures.emojiCatalog() })
            viewModel.prepareForShow()
            return viewModel
        }

        // MARK: - Drawer

        /// Builds a `DrawerViewModel` over `store` and preps it for display, the
        /// way `OverlayController.show()` does.
        @MainActor
        static func drawerViewModel(store: ClipStore) -> DrawerViewModel {
            let viewModel = DrawerViewModel(store: store, stack: PasteStack())
            viewModel.prepareForShow()
            return viewModel
        }
    }

    /// A minimal `LauncherProvider` that always returns a fixed set of rows,
    /// regardless of query — for previews and tests exercising `LauncherView`
    /// and `LauncherViewModel` without a live Spotlight/app index.
    struct StubLauncherProvider: LauncherProvider {
        let rows: [LauncherResult]
        func results(for _: String) async -> [LauncherResult] {
            self.rows
        }
    }

    /// Wraps a preview body that needs a seeded, in-memory `ClipStore`: creates
    /// one in `.task`, ingests a handful of representative pasteboard snapshots
    /// (plain text, code, a link, prose, and a flagged secret), then renders
    /// `make(store)`. Shows a spinner until seeding completes, since `#Preview`
    /// bodies are synchronous and this work is async.
    struct SeededPreview<Content: View>: View {
        let make: (ClipStore) -> Content

        @State private var store: ClipStore?

        init(@ViewBuilder make: @escaping (ClipStore) -> Content) {
            self.make = make
        }

        var body: some View {
            Group {
                if let store {
                    self.make(store)
                } else {
                    ProgressView()
                }
            }
            .task {
                guard self.store == nil else { return }
                guard let seeded = try? Fixtures.store() else { return }
                for snapshot in Self.seedSnapshots {
                    _ = try? await seeded.ingest(snapshot)
                }
                self.store = seeded
            }
        }

        private static var seedSnapshots: [PasteboardSnapshot] {
            [
                Fixtures.textSnapshot("Pick up the package before 6pm — front desk closes early on Fridays."),
                Fixtures.textSnapshot("""
                func total(for items: [Item]) -> Int {
                    items.reduce(0) { $0 + $1.byteSize }
                }
                """),
                Fixtures.textSnapshot("https://example.com/docs"),
                Fixtures.textSnapshot("""
                The quarterly report is due at the end of the month, and marketing wants \
                the updated numbers a week before that so they can fold them into the \
                deck. Finance is still reconciling last month's spend, so the figures \
                might shift slightly once that lands.
                """),
                // AWS access key shape — SecretDetector.detect flags this and the
                // store masks the preview and skips indexing it.
                Fixtures.textSnapshot("AKIAIOSFODNN7EXAMPLE"),
            ]
        }
    }
#endif
