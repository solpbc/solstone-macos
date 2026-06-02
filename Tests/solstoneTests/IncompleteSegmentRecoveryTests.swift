// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("IncompleteSegmentRecovery")
struct IncompleteSegmentRecoveryTests {
    @Test func parseTrackTypeSystemAudio() {
        let result = parseTrackType(from: "143022_audio_system.m4a", timePrefix: "143022")
        #expect(result == .systemAudio)
    }

    @Test func parseTrackTypeMicrophone() {
        let result = parseTrackType(from: "143022_audio_BuiltInMicrophoneDevice.m4a", timePrefix: "143022")
        #expect(result == .microphone(name: "BuiltInMicrophoneDevice", deviceUID: "BuiltInMicrophoneDevice"))
    }

    @Test func parseTrackTypeMalformedReturnsMicrophone() {
        let result = parseTrackType(from: "garbage.txt", timePrefix: "143022")
        #expect(result == .microphone(name: "Unknown", deviceUID: "unknown"))
    }

    @Test @MainActor func stalenessFloorUsesSegmentDurationPlusMargin() {
        #expect(IncompleteSegmentRecovery.stalenessMargin == 60)
        #expect(IncompleteSegmentRecovery.minimumStaleAge == SegmentWriter.segmentDuration + IncompleteSegmentRecovery.stalenessMargin)
    }

    @Test @MainActor func stalenessHelperSkipsJustYoungerButNotJustOlder() {
        let floor = IncompleteSegmentRecovery.minimumStaleAge
        let now = Date()

        #expect(IncompleteSegmentRecovery.shouldSkipAsTooRecent(
            creationDate: now.addingTimeInterval(-(floor - 1)),
            now: now,
            minimumAge: floor
        ))
        #expect(!IncompleteSegmentRecovery.shouldSkipAsTooRecent(
            creationDate: now.addingTimeInterval(-(floor + 1)),
            now: now,
            minimumAge: floor
        ))
    }

    @Test @MainActor func stalenessHelperSkipsNilCreationDate() {
        let floor = IncompleteSegmentRecovery.minimumStaleAge
        #expect(IncompleteSegmentRecovery.shouldSkipAsTooRecent(
            creationDate: nil,
            now: Date(),
            minimumAge: floor
        ))
    }

    @Test func recoverAllExcludesActiveSegmentByFullPath() async throws {
        let root = try makeTempDirectory("recovery-active-exclusion")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "120000",
            audio: .corrupt,
            createdSecondsAgo: 3600
        )
        let finalizer = FakeFinalizer()
        let recovery = makeScanLoopRecovery(root: root, finalizer: finalizer)

        let count = await recovery.recoverAll(excludingActiveSegment: fixture.dir.standardizedFileURL.path)
        let enqueued = enqueuedPathSet(finalizer)

        #expect(count == 0)
        #expect(!enqueued.contains(fixture.dir.standardizedFileURL.path))
    }

    @Test func recoverAllExclusionUsesFullPathNotBasename() async throws {
        let root = try makeTempDirectory("recovery-same-basename")
        defer { try? FileManager.default.removeItem(at: root) }
        let today = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "114500",
            createdSecondsAgo: 3600
        )
        let other = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-01",
            time: "114500",
            createdSecondsAgo: 3600
        )
        let finalizer = FakeFinalizer()
        let recovery = makeScanLoopRecovery(root: root, finalizer: finalizer)

        let count = await recovery.recoverAll(excludingActiveSegment: today.dir.standardizedFileURL.path)
        let enqueued = enqueuedPathSet(finalizer)

        #expect(count == 1)
        #expect(!enqueued.contains(today.dir.standardizedFileURL.path))
        #expect(enqueued.contains(other.dir.standardizedFileURL.path))
    }

    @Test func recoverAllWithExclusionMissRecoversNormally() async throws {
        let root = try makeTempDirectory("recovery-exclusion-miss")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "121500",
            createdSecondsAgo: 3600
        )
        let finalizer = FakeFinalizer()
        let recovery = makeScanLoopRecovery(root: root, finalizer: finalizer)

        let count = await recovery.recoverAll(excludingActiveSegment: root.appendingPathComponent("missing.incomplete").path)
        let enqueued = enqueuedPathSet(finalizer)

        #expect(count >= 1)
        #expect(enqueued.contains(fixture.dir.standardizedFileURL.path))
    }

    @Test func recoverAllEnqueuesEligibleOrphansRegardlessOfAudioContent() async throws {
        let root = try makeTempDirectory("recovery-audio-content")
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "123000",
            audio: .corrupt,
            createdSecondsAgo: 3600
        )
        let audioLess = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "124500",
            audio: .none,
            createdSecondsAgo: 3600
        )
        let valid = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "130000",
            createdSecondsAgo: 3600
        )
        let finalizer = FakeFinalizer()
        let recovery = makeScanLoopRecovery(root: root, finalizer: finalizer)

        let count = await recovery.recoverAll(excludingActiveSegment: nil)
        let enqueued = enqueuedPathSet(finalizer)

        #expect(count == 3)
        #expect(enqueued.contains(corrupt.dir.standardizedFileURL.path))
        #expect(enqueued.contains(audioLess.dir.standardizedFileURL.path))
        #expect(enqueued.contains(valid.dir.standardizedFileURL.path))
    }

    @Test func recoverAllExcludesInFlightSegment() async throws {
        let root = try makeTempDirectory("recovery-in-flight")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "131500",
            createdSecondsAgo: 3600
        )
        let path = fixture.dir.standardizedFileURL.path
        let finalizer = FakeFinalizer(inFlight: [path])
        let recovery = makeScanLoopRecovery(root: root, finalizer: finalizer)

        let count = await recovery.recoverAll(excludingActiveSegment: nil)
        let enqueued = enqueuedPathSet(finalizer)

        #expect(count == 0)
        #expect(!enqueued.contains(path))
    }

    @Test func recoverAllExcludesTooRecentSegment() async throws {
        let root = try makeTempDirectory("recovery-too-recent")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "133000",
            createdSecondsAgo: 1
        )
        let finalizer = FakeFinalizer()
        let recovery = makeScanLoopRecovery(root: root, finalizer: finalizer)

        let count = await recovery.recoverAll(excludingActiveSegment: nil)
        let enqueued = enqueuedPathSet(finalizer)

        #expect(count == 0)
        #expect(!enqueued.contains(fixture.dir.standardizedFileURL.path))
    }

    @Test func recoverAllContinuesAfterUnlistableDateEntry() async throws {
        let root = try makeTempDirectory("recovery-partial-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "134500",
            createdSecondsAgo: 3600
        )
        let brokenDateEntry = root.appendingPathComponent("2026-06-01")
        try Data("not a directory".utf8).write(to: brokenDateEntry)
        #expect((try? FileManager.default.contentsOfDirectory(at: brokenDateEntry, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles])) == nil)
        let finalizer = FakeFinalizer()
        let recovery = makeScanLoopRecovery(root: root, finalizer: finalizer)

        let count = await recovery.recoverAll(excludingActiveSegment: nil)
        let enqueued = enqueuedPathSet(finalizer)

        #expect(count == 1)
        #expect(enqueued.contains(fixture.dir.standardizedFileURL.path))
    }

    @Test func recoverAllEnqueuedOrphansAreFinalizedByRealQueue() async throws {
        let root = try makeTempDirectory("recovery-real-finalizer")
        defer { try? FileManager.default.removeItem(at: root) }
        let readable = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "140000",
            audio: .validM4A,
            createdSecondsAgo: 3600
        )
        let corrupt = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "141500",
            audio: .corrupt,
            createdSecondsAgo: 3600
        )
        let noVideo = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "143000",
            audio: .none,
            createdSecondsAgo: 3600
        )
        let files = try FileManager.default.contentsOfDirectory(at: noVideo.dir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "mp4" {
            try FileManager.default.removeItem(at: file)
        }

        let queue = RemixQueue { _, _ in
            AudioRemixer(verbose: false, debugKeepRejected: false)
        }
        let recovery = IncompleteSegmentRecovery(capturesDirectory: root, finalizer: queue)

        let count = await recovery.recoverAll(excludingActiveSegment: nil)
        await queue.waitForCompletion()

        let parent = readable.dir.deletingLastPathComponent()
        #expect(count == 3)
        #expect(try finalizedSegmentDirectory(in: parent, timePrefix: "140000") != nil)
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("141500.failed", isDirectory: true).path))
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("143000.failed", isDirectory: true).path))
        #expect(!FileManager.default.fileExists(atPath: readable.dir.path))
        #expect(!FileManager.default.fileExists(atPath: corrupt.dir.path))
        #expect(!FileManager.default.fileExists(atPath: noVideo.dir.path))
    }

    private func finalizedSegmentDirectory(in root: URL, timePrefix: String) throws -> URL? {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard let name = names.first(where: {
            $0.hasPrefix("\(timePrefix)_") && !$0.hasSuffix(".failed") && !$0.hasSuffix(".incomplete")
        }) else {
            return nil
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func enqueuedPathSet(_ finalizer: FakeFinalizer) -> Set<String> {
        Set(finalizer.enqueuedDirectories.all.map { $0.standardizedFileURL.path })
    }

    private func makeScanLoopRecovery(root: URL, finalizer: FakeFinalizer = FakeFinalizer()) -> IncompleteSegmentRecovery {
        IncompleteSegmentRecovery(
            verbose: false,
            capturesDirectory: root,
            finalizer: finalizer
        )
    }
}
