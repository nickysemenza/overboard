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
            ]
        ),
        .target(
            name: "OverboardUI",
            dependencies: [
                "OverboardCore",
                "OverboardMac",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Highlightr", package: "Highlightr"),
            ]
        ),
        .testTarget(
            name: "OverboardCoreTests",
            dependencies: ["OverboardCore"]
        ),
    ]
)
