// swift-tools-version: 6.2
import PackageDescription

/// Swift 6.2 "approachable concurrency": `nonisolated async` runs on the
/// caller's actor and conformances inherit their type's isolation. Mirrors
/// SWIFT_APPROACHABLE_CONCURRENCY in the app target so package and app agree.
let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    // Warnings-as-errors is NOT set here: `.treatAllWarnings(as: .error)`
    // collides with the `-suppress-warnings` Xcode passes to every package
    // target ("conflicting options") and breaks the app build. CI passes
    // `-Xswiftc -warnings-as-errors` to `swift test` instead; SwiftPM already
    // compiles dependency targets with `-suppress-warnings`, so that flag
    // only bites first-party code. The Xcode project sets
    // SWIFT_TREAT_WARNINGS_AS_ERRORS for the app target itself.
]

/// UI and AppKit-facing targets are main-actor by default; every type in them
/// was already annotated `@MainActor`. Core (data layer, actors) stays
/// nonisolated.
let mainActorByDefault: [SwiftSetting] = approachableConcurrency + [
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "OverboardKit",
    // Required before any target can carry a String Catalog.
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OverboardCore", targets: ["OverboardCore"]),
        .library(name: "OverboardMac", targets: ["OverboardMac"]),
        .library(name: "OverboardUI", targets: ["OverboardUI"]),
        .library(name: "OverboardFilePreview", targets: ["OverboardFilePreview"]),
        .executable(name: "file-index-benchmark", targets: ["FileIndexBenchmark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.1.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMinor(from: "1.6.0")),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0"),
    ],
    targets: [
        .target(
            name: "OverboardCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            resources: [
                .copy("Emoji/Resources/emoji.json"),
            ],
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "OverboardMac",
            dependencies: [
                "OverboardCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Defaults", package: "Defaults"),
            ],
            swiftSettings: mainActorByDefault
        ),
        .target(
            name: "OverboardUI",
            dependencies: [
                "OverboardCore",
                "OverboardMac",
                "OverboardFilePreview",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            resources: [
                // English-only String Catalog; the build extracts keys into it.
                .process("Resources"),
            ],
            swiftSettings: mainActorByDefault
        ),
        .target(
            name: "OverboardFilePreview",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "FileIndexBenchmark",
            dependencies: ["OverboardCore"],
            path: "Benchmarks/FileIndexBenchmark",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "OverboardCoreTests",
            dependencies: [
                "OverboardCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "OverboardMacTests",
            dependencies: ["OverboardMac", "OverboardCore"],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "OverboardUISnapshotTests",
            dependencies: [
                "OverboardUI",
                "OverboardCore",
                "OverboardMac",
                "OverboardFilePreview",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            // Recorded PNGs are read by path by SnapshotTesting, not bundled.
            exclude: ["__Snapshots__"],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "OverboardFilePreviewTests",
            dependencies: ["OverboardFilePreview"],
            swiftSettings: approachableConcurrency
        ),
    ]
)
