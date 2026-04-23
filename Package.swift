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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    targets: [
        .executableTarget(
            name: "solstone",
            dependencies: [
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
        .target(
            name: "ObjCHelpers",
            path: "Sources/ObjCHelpers",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "solstoneTests",
            dependencies: [
                .target(name: "solstone")
            ],
            path: "Tests/solstoneTests"
        )
    ]
)
