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

    @Test func takenFailedNameSetsAsideUnderTheNextFreeName() async throws {
        let root = try makeTempDirectory("incomplete-failure-taken")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let earlier = root.appendingPathComponent("051026.failed", isDirectory: true)
        try fm.createDirectory(at: earlier, withIntermediateDirectories: true)
        let incomplete = root.appendingPathComponent("051026.incomplete", isDirectory: true)
        try fm.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: incomplete.appendingPathComponent("051026_audio_system.m4a"))

        #expect(await markIncompleteSegmentAsFailed(incomplete))

        #expect(!fm.fileExists(atPath: incomplete.path))
        #expect(fm.fileExists(atPath: earlier.path))
        let next = root.appendingPathComponent("051026.2.failed", isDirectory: true)
        #expect(try Data(contentsOf: next.appendingPathComponent("051026_audio_system.m4a")) == Data("audio".utf8))
    }

    @Test func recoveryRemovesStaleSetAsideFoldersThatHoldNoRecording() async throws {
        let root = try makeTempDirectory("failed-sweep")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let day = root.appendingPathComponent("2026-09-14", isDirectory: true)
        func folder(_ name: String, files: [String], secondsAgo: TimeInterval = 3600) throws -> URL {
            let url = day.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files { try Data("x".utf8).write(to: url.appendingPathComponent(file)) }
            try fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: -secondsAgo)], ofItemAtPath: url.path)
            return url
        }
        let empty = try folder("051000.failed", files: [])
        let metaOnly = try folder("051010.2.failed", files: ["051010_meta.json", "capture_zone.json", ".DS_Store"])
        let withAudio = try folder("051020.failed", files: ["051020_meta.json", "051020_audio_system.m4a"])
        let withReceipt = try folder("051030_300.failed", files: ["051030_300_ingest_ack.json", "051030_300_audio_mic.m4a"])
        let receiptAndIntervals = try folder("051035_300.failed", files: ["051035_300_ingest_ack.json", "intake-intervals.json"])
        let withSubfolder = try folder("051040.failed", files: [])
        try fm.createDirectory(at: withSubfolder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let recent = try folder("051050.failed", files: [], secondsAgo: 5)

        let recovery = IncompleteSegmentRecovery(verbose: false, capturesDirectory: root, finalizer: FakeFinalizer())
        #expect(await recovery.recoverAll() == 0)

        #expect(!fm.fileExists(atPath: empty.path))
        #expect(!fm.fileExists(atPath: metaOnly.path))
        #expect(fm.fileExists(atPath: withAudio.path))
        #expect(fm.fileExists(atPath: withReceipt.path))
        #expect(!fm.fileExists(atPath: receiptAndIntervals.path))
        #expect(fm.fileExists(atPath: withSubfolder.path))
        #expect(fm.fileExists(atPath: recent.path))
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
