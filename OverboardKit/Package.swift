// swift-tools-version: 6.2
import PackageDescription

/// Swift 6.2 "approachable concurrency": `nonisolated async` runs on the
/// caller's actor and conformances inherit their type's isolation. Mirrors
/// SWIFT_APPROACHABLE_CONCURRENCY in the app target so package and app agree.
let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

/// UI and AppKit-facing targets are main-actor by default; every type in them
/// was already annotated `@MainActor`. Core (data layer, actors) and the CLI
/// stay nonisolated.
let mainActorByDefault: [SwiftSetting] = approachableConcurrency + [
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "OverboardKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OverboardCore", targets: ["OverboardCore"]),
        .library(name: "OverboardMac", targets: ["OverboardMac"]),
        .library(name: "OverboardUI", targets: ["OverboardUI"]),
        .library(name: "OverboardFilePreview", targets: ["OverboardFilePreview"]),
        .executable(name: "overboard", targets: ["OverboardCLI"]),
        .executable(name: "file-index-benchmark", targets: ["FileIndexBenchmark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.1.0"),
        .package(url: "https://github.com/nicklockwood/Expression", from: "0.13.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMinor(from: "1.6.0")),
        .package(url: "https://github.com/velocityzen/FileType", from: "2.2.1"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0"),
    ],
    targets: [
        .target(
            name: "OverboardCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Expression", package: "Expression"),
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
            swiftSettings: mainActorByDefault
        ),
        .target(
            name: "OverboardFilePreview",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "FileType", package: "FileType"),
            ],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(
            name: "OverboardCLI",
            dependencies: ["OverboardCore"],
            swiftSettings: approachableConcurrency
        ),
        .executableTarget(
            name: "FileIndexBenchmark",
            dependencies: ["OverboardCore"],
            path: "Benchmarks/FileIndexBenchmark",
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "OverboardCoreTests",
            dependencies: ["OverboardCore"],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "OverboardMacTests",
            dependencies: ["OverboardMac", "OverboardCore"],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "OverboardCLITests",
            dependencies: ["OverboardCLI"],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "OverboardUISnapshotTests",
            dependencies: [
                "OverboardUI",
                "OverboardCore",
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
