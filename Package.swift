// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexUsageHUD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexUsageHUD", targets: ["CodexUsageHUD"]),
        .executable(name: "ClaudeUsageBridge", targets: ["ClaudeUsageBridge"])
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageHUD",
            linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ClaudeUsageBridge"),
        .testTarget(
            name: "CodexUsageHUDTests",
            dependencies: ["CodexUsageHUD"],
            linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
