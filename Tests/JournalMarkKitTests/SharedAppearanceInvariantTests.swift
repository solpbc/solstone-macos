// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import MacTestSupport
import Testing

/// The shared modules both apps draw with never set the appearance; the Journal app scans its own
/// sources the same way in its package.
@Suite("Shared modules follow the system appearance")
struct SharedAppearanceInvariantTests {
    @Test func nothingInTheSharedModulesSetsTheAppearance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for dir in ["Sources/SolstoneCore", "Sources/JournalMarkKit"] {
            let files = try #require(AppearanceSourceAssertions.swiftFiles(under: root.appendingPathComponent(dir)))
            #expect(!files.isEmpty, "no Swift sources under \(dir)")
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                let violations = AppearanceSourceAssertions.violations(in: source, file: file.lastPathComponent)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            }
        }
    }
}
