// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("IncompleteSegmentRecovery")
struct IncompleteSegmentRecoveryTests {
    private let recovery = IncompleteSegmentRecovery(verbose: false)

    @Test func parseTrackTypeSystemAudio() {
        let result = recovery.parseTrackType(from: "143022_audio_system.m4a", timePrefix: "143022")
        #expect(result == .systemAudio)
    }

    @Test func parseTrackTypeMicrophone() {
        let result = recovery.parseTrackType(from: "143022_audio_BuiltInMicrophoneDevice.m4a", timePrefix: "143022")
        #expect(result == .microphone(name: "BuiltInMicrophoneDevice", deviceUID: "BuiltInMicrophoneDevice"))
    }

    @Test func parseTrackTypeMalformedReturnsMicrophone() {
        let result = recovery.parseTrackType(from: "garbage.txt", timePrefix: "143022")
        #expect(result == .microphone(name: "Unknown", deviceUID: "unknown"))
    }

    @Test func recoverSegmentMarksFailedWhenRemixThrows() async throws {
        let root = try makeTempDirectory("recovery-remix-throws")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeRecoverableSegment(root: root)

        let recovery = IncompleteSegmentRecovery(
            verbose: false,
            remixerFactory: { _ in FakeRemixer(.throwing(SyntheticRemixError())) }
        )

        let recovered = await recovery.recoverSegment(at: fixture.dir)

        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)
        #expect(recovered == false)
        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(fixture.audio.lastPathComponent).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.dir.path))
    }

    @Test func recoverSegmentContinuesWhenNoTracksToWrite() async throws {
        let root = try makeTempDirectory("recovery-no-tracks")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeRecoverableSegment(root: root)

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
        let fixture = try await makeRecoverableSegment(root: root)
        let fakeRemixer = FakeRemixer(.success)

        let recovery = IncompleteSegmentRecovery(
            verbose: false,
            remixerFactory: { _ in fakeRemixer }
        )

        let recovered = await recovery.recoverSegment(at: fixture.dir)

        #expect(recovered == true)
        #expect(fakeRemixer.recordedSilenceMusic.all == [true])
    }

    private func makeRecoverableSegment(root: URL) async throws -> (dir: URL, audio: URL) {
        let dir = root.appendingPathComponent("120000.incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let video = dir.appendingPathComponent("120000_display_42_screen.mp4")
        let audio = dir.appendingPathComponent("120000_audio_system.m4a")
        try await makeTinyValidMP4(at: video, seconds: 1.2)
        try await makeTinyValidM4A(at: audio)

        return (dir, audio)
    }

    private func finalizedSegmentDirectory(in root: URL, timePrefix: String) throws -> URL? {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard let name = names.first(where: { $0.hasPrefix("\(timePrefix)_") }) else {
            return nil
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }
}
