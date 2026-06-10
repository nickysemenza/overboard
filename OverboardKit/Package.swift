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
    ],
    targets: [
        .target(
            name: "OverboardCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
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
            ]
        ),
        .testTarget(
            name: "OverboardCoreTests",
            dependencies: ["OverboardCore"]
        ),
    ]
)
