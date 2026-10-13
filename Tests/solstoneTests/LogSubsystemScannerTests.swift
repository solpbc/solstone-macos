// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import MacTestSupport
import SolstoneCore
import Testing
@testable import solstone

@Suite("LogSubsystemScanner")
struct LogSubsystemScannerTests {
    @Test func sourcesWalkPassesAgainstAllForPersistedHelp() throws {
        let files = try swiftSourceFiles(under: repositorySources())
        let result = scanLogSubsystemConstructions(files)
        #expect(result.ok, "\(result.failures.joined(separator: "\n"))")
    }

    @Test func unknownSubsystemLiteralFails() {
        let result = scanLogSubsystemConstructions([
            (
                path: "fixture.swift",
                contents: """
                import os
                let log = Logger(subsystem: "app.solstone.not-a-real-subsystem", category: "x")
                """
            )
        ])
        #expect(!result.ok)
        #expect(result.failures.contains { $0.contains("app.solstone.not-a-real-subsystem") })
    }

    @Test func unknownSolstoneLogSubsystemMemberFails() {
        let result = scanLogSubsystemConstructions([
            (
                path: "fixture.swift",
                contents: """
                import os
                let log = Logger(subsystem: SolstoneLogSubsystem.notInTheHelpSet, category: "x")
                """
            )
        ])
        #expect(!result.ok)
        #expect(result.failures.contains { $0.contains("notInTheHelpSet") })
    }

    @Test func emptyFileListFails() {
        let result = scanLogSubsystemConstructions([])
        #expect(!result.ok)
    }

    @Test func filesWithNoConstructionsFail() {
        let result = scanLogSubsystemConstructions([
            (path: "empty.swift", contents: "import Foundation\nstruct Foo {}\n")
        ])
        #expect(!result.ok)
    }
}

private func repositorySources() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)
}
