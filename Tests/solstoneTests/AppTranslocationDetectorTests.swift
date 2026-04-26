// SPDX-License-Identifier: AGPL-3.0-only
//
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("AppTranslocationDetector")
struct AppTranslocationDetectorTests {
    @Test func isTranslocatedReturnsBoolWithoutThrowing() {
        _ = AppTranslocationDetector.isTranslocated()
    }

    @Test func pathBackstopReturnsTrueWhenApiNilAndBundlePathLooksTranslocated() {
        #expect(
            AppTranslocationDetector.isTranslocated(
                bundlePath: "/private/var/folders/zz/AppTranslocation/abc/d/solstone.app",
                apiResult: nil
            )
        )
    }

    @Test func pathBackstopReturnsFalseWhenApiNilAndBundlePathLooksNormal() {
        #expect(
            AppTranslocationDetector.isTranslocated(
                bundlePath: "/Applications/solstone.app",
                apiResult: nil
            ) == false
        )
    }

    @Test func apiResultIsTrustedWhenPresent() {
        #expect(
            AppTranslocationDetector.isTranslocated(
                bundlePath: "/Applications/solstone.app",
                apiResult: true
            )
        )
        #expect(
            AppTranslocationDetector.isTranslocated(
                bundlePath: "/private/var/folders/zz/AppTranslocation/abc/d/solstone.app",
                apiResult: false
            ) == false
        )
    }
}
