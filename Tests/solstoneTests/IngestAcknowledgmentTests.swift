// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Testing
@testable import solstone

@Suite("Ingest acknowledgment")
struct IngestAcknowledgmentTests {
    @Test func unchangedFileSkipsHashButSameSizeRewriteRestoringMtimeDoesNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("120000_300_audio.m4a")
        try Data("before".utf8).write(to: file)
        let version = try #require(IngestLocalFileVersion.read(file))
        let proof = IngestAcknowledgedFileProof(submitted: file.lastPathComponent, sha256: "before-hash", size: 6, localVersion: version)
        var calls = 0
        #expect(proof.matchesLocalFileForUpload(file) { _ in calls += 1; return "before-hash" })
        #expect(calls == (version.hasSubsecondTimes ? 0 : 1))
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("after!".utf8))
        try handle.close()
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(version.modifiedSeconds), tv_nsec: Int(version.modifiedNanoseconds))]
        #expect(utimensat(AT_FDCWD, file.path, &times, 0) == 0)
        calls = 0
        #expect(!proof.matchesLocalFileForUpload(file) { _ in calls += 1; return "after-hash" })
        #expect(calls == 1)
        let link = root.appendingPathComponent("link_screen.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(IngestLocalFileVersion.read(link) == nil)
        #expect(IngestLocalFileVersion.read(root) == nil)
    }

    @Test func malformedReceiptCannotAuthorizeMediaOrMetadataRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("receipt.json")
        let valid = IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: String(repeating: "a", count: 64), size: 1)
        let metadata = IngestAcknowledgedFileProof(submitted: "120000_300_meta.json", sha256: valid.sha256, size: 1)
        for files in [[valid, valid], [metadata]] {
            let receipt = IngestAcknowledgment(journalFingerprint: "journal", day: "20260901", submittedSegment: "120000_300", storedSegmentKey: "120000_300", status: .ok, payload: .init(files: files, meta: [:]))
            // Simulate a corrupt on-disk receipt, bypassing the writer's validation.
            try JSONEncoder().encode(receipt).write(to: url)
            #expect(IngestAcknowledgmentStore.read(from: url) == nil)
            #expect(throws: IngestAcknowledgmentStoreError.invalidAcknowledgment) {
                try IngestAcknowledgmentStore.write(receipt, to: url)
            }
        }
    }
}
