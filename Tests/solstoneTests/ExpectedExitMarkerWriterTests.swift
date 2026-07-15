// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SolstoneCore

@Suite("ExpectedExitMarker writer")
struct ExpectedExitMarkerWriterTests {
    @Test func markExpectedExitRoundTripsAndValidates() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("expected-exit.json")
        ExpectedExitMarker.markExpectedExit(reason: "test", at: url)

        let marker = try #require(ExpectedExitMarker.readAndConsume(at: url))
        #expect(marker.reason == "test")
        #expect(marker.pid == getpid())
        #expect(ExpectedExitMarker.isExpectedExit(marker: marker, terminatedPID: getpid(), now: Date()))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func markExpectedExitCreatesParentDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sub", isDirectory: true)
            .appendingPathComponent("expected-exit.json")

        ExpectedExitMarker.markExpectedExit(reason: "nested", at: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let marker = try ExpectedExitMarker.decode(Data(contentsOf: url))
        #expect(marker.reason == "nested")
        #expect(marker.pid == getpid())
    }

    @Test func markExpectedExitHonorsCustomPIDAndNow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("expected-exit.json")
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        let pid: Int32 = 4242

        ExpectedExitMarker.markExpectedExit(reason: "custom", now: now, pid: pid, at: url)

        let marker = try #require(ExpectedExitMarker.readAndConsume(at: url))
        #expect(marker.reason == "custom")
        #expect(marker.pid == pid)
        #expect(marker.timestamp == now)
    }

    @Test func markExpectedExitWriteFailureDoesNotThrow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let regularFile = directory.appendingPathComponent("not-a-directory")
        _ = FileManager.default.createFile(atPath: regularFile.path, contents: Data())
        let url = regularFile
            .appendingPathComponent("sub", isDirectory: true)
            .appendingPathComponent("expected-exit.json")

        ExpectedExitMarker.markExpectedExit(reason: "blocked", at: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func durableWriteVerifiesCurrentPIDAndLeavesMarkerUnconsumed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("expected-exit.json")
        let now = Date(timeIntervalSinceReferenceDate: 4_000)
        let pid: Int32 = 9_001

        let marker = try ExpectedExitMarker.writeAndVerifyExpectedExit(
            reason: "placement-repair",
            now: now,
            pid: pid,
            at: url
        )

        #expect(marker == ExpectedExitMarker(pid: pid, timestamp: now, reason: "placement-repair"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        let consumed = try #require(ExpectedExitMarker.readAndConsume(at: url))
        #expect(consumed == marker)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func durableWriteCreatesParentDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sub", isDirectory: true)
            .appendingPathComponent("expected-exit.json")

        let marker = try ExpectedExitMarker.writeAndVerifyExpectedExit(reason: "durable", pid: 123, at: url)

        #expect(marker.pid == 123)
        #expect(marker.reason == "durable")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func durableWriteThrowsWhenParentCannotBeCreated() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let regularFile = directory.appendingPathComponent("not-a-directory")
        _ = FileManager.default.createFile(atPath: regularFile.path, contents: Data())
        let url = regularFile
            .appendingPathComponent("sub", isDirectory: true)
            .appendingPathComponent("expected-exit.json")

        #expect(throws: ExpectedExitMarkerDurableWriteError.self) {
            try ExpectedExitMarker.writeAndVerifyExpectedExit(reason: "blocked", at: url)
        }
    }

    @Test func invalidateRemovesExistingMarker() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("expected-exit.json")
        ExpectedExitMarker.markExpectedExit(reason: "test", at: url)

        ExpectedExitMarker.invalidate(at: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func invalidateMissingMarkerIsNoOp() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("expected-exit.json")

        ExpectedExitMarker.invalidate(at: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func invalidateFailureDoesNotThrow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let regularFile = directory.appendingPathComponent("not-a-directory")
        _ = FileManager.default.createFile(atPath: regularFile.path, contents: Data())
        let url = regularFile
            .appendingPathComponent("sub", isDirectory: true)
            .appendingPathComponent("expected-exit.json")

        ExpectedExitMarker.invalidate(at: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-expected-exit-writer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
