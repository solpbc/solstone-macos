// swift-tools-version: 6.1
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import PackageDescription

let package = Package(
    name: "solstone",
    platforms: [
        .macOS(.v15)
    ],
    // The shared Mac libraries the Journal app consumes at an exact revision of this
    // repository (solstone-journal, platforms/macos). The capture app and its helpers
    // stay local to this package.
    products: [
        .library(name: "SolstoneCore", targets: ["SolstoneCore"]),
        .library(name: "JournalMarkKit", targets: ["JournalMarkKit"]),
        .library(name: "UpdateKit", targets: ["UpdateKit"]),
        .library(name: "Sparkle", targets: ["Sparkle"]),
        .library(name: "WatchdogKit", targets: ["WatchdogKit"]),
        .library(name: "MacTestSupport", targets: ["MacTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/solpbc/spl-swift.git", exact: "0.8.6")
    ],
    targets: [
        .binaryTarget(name: "Sparkle", path: "vendor/sparkle/Sparkle.xcframework"),
        .target(
            name: "SolstoneCore",
            path: "Sources/SolstoneCore",
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
        .target(
            name: "UpdateKit",
            dependencies: [
                .target(name: "SolstoneCore"),
                .target(name: "Sparkle")
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
                .product(name: "SPLTunnel", package: "spl-swift"),
                .target(name: "ObjCHelpers"),
                .target(name: "Sparkle"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/solstone",
            exclude: [
                "Info.plist",
                "entitlements.plist",
                "app.solstone.observer.watchdog.plist",
                "host-contract.provenance.json"
            ],
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("SOLSTONE_BROWSER_INTAKE_PREVIEW", .when(configuration: .debug))
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SoundAnalysis"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "WatchdogKit",
            dependencies: [
                .target(name: "SolstoneCore")
            ],
            path: "Sources/WatchdogKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "solstone-watchdog",
            dependencies: [
                .target(name: "WatchdogKit")
            ],
            path: "Sources/solstone-watchdog",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "solstone-browser-host",
            path: "Sources/solstone-browser-host",
            exclude: ["entitlements.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("SOLSTONE_BROWSER_INTAKE_PREVIEW", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "ObjCHelpers",
            path: "Sources/ObjCHelpers",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MacTestSupport",
            dependencies: [
                .target(name: "SolstoneCore")
            ],
            path: "Tests/MacTestSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "JournalMarkKitTests",
            dependencies: [
                .target(name: "JournalMarkKit"),
                .target(name: "MacTestSupport"),
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
                .target(name: "Sparkle")
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
                .target(name: "JournalMarkKit"),
                .target(name: "UpdateKit"),
                .product(name: "SPLTunnel", package: "spl-swift"),
                .target(name: "MacTestSupport"),
                .target(name: "WatchdogKit")
            ],
            path: "Tests/solstoneTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("SOLSTONE_BROWSER_INTAKE_PREVIEW", .when(configuration: .debug))
            ]
        ),
    ]
)
