// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Incomplete segment failure marker")
struct IncompleteSegmentFailureTests {
    @Test func renamesIncompleteDirectoryToFailedMarker() async throws {
        let root = try makeTempDirectory("incomplete-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let incomplete = root.appendingPathComponent("120000.incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)

        await markIncompleteSegmentAsFailed(incomplete)

        #expect(!FileManager.default.fileExists(atPath: incomplete.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path))
    }

    @Test func nonIncompletePathIsLeftUntouched() async throws {
        let root = try makeTempDirectory("incomplete-failure-non")
        defer { try? FileManager.default.removeItem(at: root) }
        let complete = root.appendingPathComponent("120000_12", isDirectory: true)
        try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true)

        await markIncompleteSegmentAsFailed(complete)

        #expect(FileManager.default.fileExists(atPath: complete.path))
    }
}
