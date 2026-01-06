// swift-tools-version: 6.1
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import PackageDescription

let package = Package(
    name: "SolstoneCaptureCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SolstoneCaptureCore", targets: ["SolstoneCaptureCore"])
    ],
    targets: [
        .target(
            name: "ObjCHelpers",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SolstoneCaptureCore",
            dependencies: ["ObjCHelpers"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio")
            ]
        )
    ]
)
