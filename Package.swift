// swift-tools-version: 6.1
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import PackageDescription

let package = Package(
    name: "solstone",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "SolstoneCore",
            path: "Sources/SolstoneCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "solstone",
            dependencies: [
                .target(name: "SolstoneCore"),
                .target(name: "ObjCHelpers"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/solstone",
            exclude: [
                "Info.plist",
                "entitlements.plist"
            ],
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SoundAnalysis")
            ]
        ),
        .executableTarget(
            name: "sol-mac",
            dependencies: [
                .target(name: "SolstoneCore"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/sol-mac",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ObjCHelpers",
            path: "Sources/ObjCHelpers",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "solstoneTests",
            dependencies: [
                .target(name: "solstone"),
                .target(name: "SolstoneCore"),
                .target(name: "sol-mac")
            ],
            path: "Tests/solstoneTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
