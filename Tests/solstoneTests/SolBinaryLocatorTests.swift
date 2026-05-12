// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SolBinaryLocator")
struct SolBinaryLocatorTests {
    @Test func findSolBinary_returnsPreferredPathWhenExists() async {
        let preferred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/sol").path
        guard FileManager.default.fileExists(atPath: preferred) else {
            return
        }

        let found = await SolBinaryLocator.findSolBinary()
        #expect(found == preferred)
    }

    @Test func findSolBinary_returnsSolPathWhenPresent() async {
        let found = await SolBinaryLocator.findSolBinary()
        guard let found else {
            return
        }

        #expect(found.hasSuffix("/sol"))
    }
}
