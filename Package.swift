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
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "SolstoneCore",
            path: "Sources/SolstoneCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "SPLTunnel",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/SPLTunnel",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "solstone",
            dependencies: [
                .target(name: "SolstoneCore"),
                .target(name: "SPLTunnel"),
                .target(name: "ObjCHelpers"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/solstone",
            exclude: [
                "Info.plist",
                "entitlements.plist",
                "app.solstone.observer.watchdog.plist"
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
                .target(name: "SPLTunnel"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/sol-mac",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "solstone-watchdog",
            dependencies: [
                .target(name: "SolstoneCore")
            ],
            path: "Sources/solstone-watchdog",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit")
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
                .target(name: "sol-mac"),
                .target(name: "solstone-watchdog")
            ],
            path: "Tests/solstoneTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SPLTunnelTests",
            dependencies: [.target(name: "SPLTunnel")],
            path: "Tests/SPLTunnelTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
