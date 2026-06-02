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

    @Test func recoverSegmentMarksFailedWhenRemixThrows() async throws {
        let root = try makeTempDirectory("recovery-remix-throws")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(root: root)
        let audio = try #require(fixture.audio)

        let recovery = IncompleteSegmentRecovery(
            verbose: false,
            remixerFactory: { _ in FakeRemixer(.throwing(SyntheticRemixError())) }
        )

        let recovered = await recovery.recoverSegment(at: fixture.dir)

        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)
        #expect(recovered == false)
        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(audio.lastPathComponent).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.dir.path))
    }

    @Test func recoverSegmentContinuesWhenNoTracksToWrite() async throws {
        let root = try makeTempDirectory("recovery-no-tracks")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(root: root)

        let recovery = IncompleteSegmentRecovery(
            verbose: false,
            remixerFactory: { _ in FakeRemixer(.throwing(AudioRemixerError.noTracksToWrite)) }
        )

        let recovered = await recovery.recoverSegment(at: fixture.dir)

        let finalizedDir = try finalizedSegmentDirectory(in: root, timePrefix: "120000")
        let finalDir = try #require(finalizedDir)
        #expect(recovered == true)
        #expect(FileManager.default.fileExists(atPath: finalDir.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path))
    }

    @Test func recoverSegmentUsesFactoryAndPassesSilenceMusicTrue() async throws {
        let root = try makeTempDirectory("recovery-silence-music")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(root: root)
        let fakeRemixer = FakeRemixer(.success)

        let recovery = IncompleteSegmentRecovery(
            verbose: false,
            remixerFactory: { _ in fakeRemixer }
        )

        let recovered = await recovery.recoverSegment(at: fixture.dir)

        #expect(recovered == true)
        #expect(fakeRemixer.recordedSilenceMusic.all == [true])
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
        let recovery = makeScanLoopRecovery(root: root)

        let count = await recovery.recoverAll(excludingActiveSegment: fixture.dir.standardizedFileURL.path)
        let parent = fixture.dir.deletingLastPathComponent()

        #expect(count == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.dir.path))
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("120000.failed", isDirectory: true).path))
        #expect(try finalizedSegmentDirectory(in: parent, timePrefix: "120000") == nil)
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
        let recovery = makeScanLoopRecovery(root: root)

        _ = await recovery.recoverAll(excludingActiveSegment: today.dir.standardizedFileURL.path)
        let otherParent = other.dir.deletingLastPathComponent()

        #expect(FileManager.default.fileExists(atPath: today.dir.path))
        #expect(!FileManager.default.fileExists(atPath: other.dir.path))
        #expect(try finalizedSegmentDirectory(in: otherParent, timePrefix: "114500") != nil)
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
        let recovery = makeScanLoopRecovery(root: root)

        let count = await recovery.recoverAll(excludingActiveSegment: root.appendingPathComponent("missing.incomplete").path)
        let parent = fixture.dir.deletingLastPathComponent()

        #expect(count >= 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.dir.path))
        #expect(try finalizedSegmentDirectory(in: parent, timePrefix: "121500") != nil)
    }

    @Test func recoverAllMarksCorruptExpectedAudioFailed() async throws {
        let root = try makeTempDirectory("recovery-corrupt-audio")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "123000",
            audio: .corrupt,
            createdSecondsAgo: 3600
        )
        let recovery = makeScanLoopRecovery(root: root)

        let count = await recovery.recoverAll(excludingActiveSegment: nil)
        let parent = fixture.dir.deletingLastPathComponent()

        #expect(count == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.dir.path))
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("123000.failed", isDirectory: true).path))
        #expect(try finalizedSegmentDirectory(in: parent, timePrefix: "123000") == nil)
    }

    @Test func recoverAllFinalizesAudioLessScreenOnlySegment() async throws {
        let root = try makeTempDirectory("recovery-screen-only")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "124500",
            audio: .none,
            createdSecondsAgo: 3600
        )
        let recovery = makeScanLoopRecovery(root: root)

        let count = await recovery.recoverAll(excludingActiveSegment: nil)
        let parent = fixture.dir.deletingLastPathComponent()

        #expect(count >= 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.dir.path))
        #expect(try finalizedSegmentDirectory(in: parent, timePrefix: "124500") != nil)
    }

    @Test func recoverAllFinalizesValidAudioSegment() async throws {
        let root = try makeTempDirectory("recovery-valid-audio")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIncompleteSegment(
            root: root,
            date: "2026-06-02",
            time: "130000",
            createdSecondsAgo: 3600
        )
        let recovery = makeScanLoopRecovery(root: root)

        let count = await recovery.recoverAll(excludingActiveSegment: nil)
        let parent = fixture.dir.deletingLastPathComponent()

        #expect(count >= 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.dir.path))
        #expect(try finalizedSegmentDirectory(in: parent, timePrefix: "130000") != nil)
    }

    private func finalizedSegmentDirectory(in root: URL, timePrefix: String) throws -> URL? {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard let name = names.first(where: { $0.hasPrefix("\(timePrefix)_") }) else {
            return nil
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func makeScanLoopRecovery(root: URL) -> IncompleteSegmentRecovery {
        IncompleteSegmentRecovery(
            verbose: false,
            capturesDirectory: root,
            remixerFactory: { _ in FakeRemixer(.success) }
        )
    }
}
