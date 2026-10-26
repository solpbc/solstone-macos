// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("AppVersion")
struct AppVersionTests {
    @Test func reportedCarriesTheBuildAsSemverBuildMetadata() {
        #expect(AppVersion.reported(short: "2.0.48", build: "128") == "2.0.48+128")
    }

    @Test func reportedFallsBackToTheShortVersionWithoutARealBuild() {
        #expect(AppVersion.reported(short: "2.0.48", build: "") == "2.0.48")
        #expect(AppVersion.reported(short: "2.0.48", build: "unknown") == "2.0.48")
    }

    @Test func reportedPropertyComposesTheBundleValues() {
        #expect(AppVersion.reported == AppVersion.reported(short: AppVersion.short, build: AppVersion.build))
    }
}
