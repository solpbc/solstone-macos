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
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "SolstoneCore",
            path: "Sources/SolstoneCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .target(
            name: "JournalRuntime",
            dependencies: [
                .target(name: "SolstoneCore")
            ],
            path: "Sources/JournalRuntime",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "JournalMarkKit",
            dependencies: [
                .target(name: "SolstoneCore")
            ],
            path: "Sources/JournalMarkKit",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText")
            ]
        ),
        .executableTarget(
            name: "journal-icon-gen",
            dependencies: ["JournalMarkKit"],
            path: "Sources/journal-icon-gen",
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
        .target(
            name: "UpdateKit",
            dependencies: [
                .target(name: "SolstoneCore"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/UpdateKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "solstone",
            dependencies: [
                .target(name: "SolstoneCore"),
                .target(name: "JournalMarkKit"),
                .target(name: "UpdateKit"),
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
        .executableTarget(
            name: "journal",
            dependencies: [
                .target(name: "SolstoneCore"),
                .target(name: "JournalRuntime"),
                .target(name: "JournalMarkKit"),
                .target(name: "UpdateKit"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/journal",
            exclude: [
                "Info.plist",
                "entitlements.plist",
                "app.solstone.journal.watchdog.plist"
            ],
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .target(
            name: "ObjCHelpers",
            path: "Sources/ObjCHelpers",
            publicHeadersPath: "include"
        ),
        .target(
            name: "JournalRuntimeTestSupport",
            dependencies: [
                .target(name: "JournalRuntime"),
                .target(name: "SolstoneCore")
            ],
            path: "Tests/JournalRuntimeTestSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "JournalRuntimeTests",
            dependencies: [
                .target(name: "JournalRuntime"),
                .target(name: "JournalRuntimeTestSupport"),
                .target(name: "SolstoneCore")
            ],
            path: "Tests/JournalRuntimeTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "JournalMarkKitTests",
            dependencies: [
                .target(name: "JournalMarkKit"),
                .target(name: "JournalRuntimeTestSupport"),
                .target(name: "SolstoneCore")
            ],
            path: "Tests/JournalMarkKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "UpdateKitTests",
            dependencies: [
                .target(name: "UpdateKit"),
                .target(name: "SolstoneCore"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Tests/UpdateKitTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "solstoneTests",
            dependencies: [
                .target(name: "solstone"),
                .target(name: "SolstoneCore"),
                .target(name: "JournalRuntime"),
                .target(name: "JournalMarkKit"),
                .target(name: "UpdateKit"),
                .target(name: "JournalRuntimeTestSupport"),
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
            name: "journalTests",
            dependencies: [
                .target(name: "journal"),
                .target(name: "JournalMarkKit"),
                .target(name: "JournalRuntime"),
                .target(name: "JournalRuntimeTestSupport"),
                .target(name: "SolstoneCore"),
                .target(name: "UpdateKit")
            ],
            path: "Tests/journalTests",
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
