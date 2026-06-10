// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OverboardKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OverboardCore", targets: ["OverboardCore"]),
        .library(name: "OverboardMac", targets: ["OverboardMac"]),
        .library(name: "OverboardUI", targets: ["OverboardUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.1.0"),
        .package(url: "https://github.com/nicklockwood/Expression", from: "0.13.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0"),
    ],
    targets: [
        .target(
            name: "OverboardCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Expression", package: "Expression"),
            ]
        ),
        .target(
            name: "OverboardMac",
            dependencies: [
                "OverboardCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Defaults", package: "Defaults"),
            ]
        ),
        .target(
            name: "OverboardUI",
            dependencies: [
                "OverboardCore",
                "OverboardMac",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        .testTarget(
            name: "OverboardCoreTests",
            dependencies: ["OverboardCore"]
        ),
        .testTarget(
            name: "OverboardUISnapshotTests",
            dependencies: [
                "OverboardUI",
                "OverboardCore",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
    ]
)
