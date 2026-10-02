// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import SolstoneCore
import Testing
@testable import solstone

@Suite(.serialized)
@MainActor
struct CaptureSegmentNamingTests {
    private struct NoopRecovery: IncompleteSegmentRecovering, Sendable {
        func recoverAll(excludingActiveSegment activeSegmentPath: String?) async -> Int { 0 }
    }

    private final class LockedValue<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ initial: T) { self.value = initial }
        var current: T { lock.withLock { value } }
        func set(_ newValue: T) { lock.withLock { value = newValue } }
    }

    private static func isoDate(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: string) else {
            struct DateParseError: Error {}
            throw DateParseError()
        }
        return date
    }

    @MainActor
    private final class NamingCaptureSegment: CaptureSegmentWriting, @unchecked Sendable {
        let outputDirectory: URL
        let timePrefix: String

        init(outputDirectory: URL, timePrefix: String) {
            self.outputDirectory = outputDirectory
            self.timePrefix = timePrefix
        }

        func start(
            sources: CaptureSources,
            displayInfos: [DisplayInfo],
            filters: [CGDirectDisplayID: SCContentFilter],
            audioFilter: SCContentFilter?,
            mics: [AudioInputDevice],
            micCaptureManager: MicrophoneCaptureManager?,
            systemAudioCaptureManager: SystemAudioCaptureManager?
        ) async throws -> CaptureSources {
            let mediaFile = outputDirectory.appendingPathComponent("\(timePrefix)_display_1_screen.mp4")
            try Data("screen-media-bytes".utf8).write(to: mediaFile)
            return sources
        }

        func finishCapture() async -> SegmentCaptureResult? {
            SegmentCaptureResult(
                segmentDirectory: outputDirectory,
                timePrefix: timePrefix,
                capturedDurationSeconds: 300,
                audioInputs: [],
                silenceMusic: true,
                micMetadataJSON: nil
            )
        }

        func updateContentFilter(_ filters: [CGDirectDisplayID: SCContentFilter]) async throws {}
        func addMicrophone(_ device: AudioInputDevice) throws {}
        func removeMicrophone(deviceUID: String) {}
        func hasMicrophone(deviceUID: String) -> Bool { false }
        func activeMicrophoneUIDs() -> [String] { [] }
    }

    @MainActor
    private final class SeedCaptureSegment: CaptureSegmentWriting, @unchecked Sendable {
        let outputDirectory: URL
        init(outputDirectory: URL) { self.outputDirectory = outputDirectory }
        func start(
            sources: CaptureSources,
            displayInfos: [DisplayInfo],
            filters: [CGDirectDisplayID: SCContentFilter],
            audioFilter: SCContentFilter?,
            mics: [AudioInputDevice],
            micCaptureManager: MicrophoneCaptureManager?,
            systemAudioCaptureManager: SystemAudioCaptureManager?
        ) async throws -> CaptureSources { sources }
        func finishCapture() async -> SegmentCaptureResult? { nil }
        func updateContentFilter(_ filters: [CGDirectDisplayID: SCContentFilter]) async throws {}
        func addMicrophone(_ device: AudioInputDevice) throws {}
        func removeMicrophone(deviceUID: String) {}
        func hasMicrophone(deviceUID: String) -> Bool { false }
        func activeMicrophoneUIDs() -> [String] { [] }
    }

    @Test func repeatedHour() async throws {
        let previousDuration = SegmentWriter.segmentDuration
        SegmentWriter.segmentDuration = 300
        defer { SegmentWriter.segmentDuration = previousDuration }

        let root = try makeTempDirectory("naming-repeated-hour")
        defer { try? FileManager.default.removeItem(at: root) }

        let dayDir = root.appendingPathComponent("2026-10-25", isDirectory: true)
        let firstDir = dayDir.appendingPathComponent("023000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)

        let firstZoneURL = firstDir.appendingPathComponent(StorageManager.captureZoneFileName)
        try Data("{\"tz\":\"Europe/Berlin\",\"utc_offset_seconds\":7200}".utf8).write(to: firstZoneURL)
        let firstMediaURL = firstDir.appendingPathComponent("023000_300_display_1_screen.mp4")
        try Data("initial-media".utf8).write(to: firstMediaURL)

        let savedFirstZone = try Data(contentsOf: firstZoneURL)
        let savedFirstMedia = try Data(contentsOf: firstMediaURL)

        let queue = RemixQueue()
        let startInstant = try Self.isoDate("2026-10-25T01:30:00Z")
        let zone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let zoneSource = CaptureZoneSource { zone }

        let storage = StorageManager(baseDirectory: root)
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { NoopRecovery() })
        let manager = CaptureManager(
            storageManager: storage,
            segmentFactory: { dir, prefix, _, _ in NamingCaptureSegment(outputDirectory: dir, timePrefix: prefix) },
            recoveryCoordinator: coordinator,
            finalizer: queue,
            captureZoneSource: zoneSource,
            now: { startInstant },
            allowsEmptyDisplayConfigurationForTesting: true,
            microphoneDevices: { [] }
        )

        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        let startOutcome = await executor.enqueue(.start(reason: .user, sources: .screen, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = startOutcome else {
            Issue.record("expected start to commit")
            return
        }

        let stopOutcome = await executor.enqueue(.stop(reason: .user))
        guard case .committed = stopOutcome else {
            Issue.record("expected stop to commit")
            return
        }
        await queue.waitForCompletion()

        let secondDir = dayDir.appendingPathComponent("023001_300", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: secondDir.path))

        let secondMediaURL = secondDir.appendingPathComponent("023001_300_display_1_screen.mp4")
        #expect(FileManager.default.fileExists(atPath: secondMediaURL.path))
        let secondMediaData = try Data(contentsOf: secondMediaURL)
        #expect(!secondMediaData.isEmpty)

        let secondZoneURL = secondDir.appendingPathComponent(StorageManager.captureZoneFileName)
        #expect(FileManager.default.fileExists(atPath: secondZoneURL.path))
        let secondZoneData = try Data(contentsOf: secondZoneURL)
        let secondZoneDict = try JSONSerialization.jsonObject(with: secondZoneData) as? [String: Any]
        #expect(secondZoneDict?["tz"] as? String == "Europe/Berlin")
        #expect(secondZoneDict?["utc_offset_seconds"] as? Int == 3600)

        #expect(try Data(contentsOf: firstZoneURL) == savedFirstZone)
        #expect(try Data(contentsOf: firstMediaURL) == savedFirstMedia)

        let syncService = SyncService(
            storageManager: storage,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:9") }
        )
        let snapshot = await syncService.discover()
        let candidates = snapshot.candidatesByDay["20261025"] ?? []
        let segments = candidates.map(\.segmentURL.lastPathComponent)
        #expect(segments.contains("023000_300"))
        #expect(segments.contains("023001_300"))
        let secondCandidate = try #require(candidates.first { $0.segmentURL.lastPathComponent == "023001_300" })
        #expect(!secondCandidate.media.isEmpty)
    }

    @Test func travel() async throws {
        let previousDuration = SegmentWriter.segmentDuration
        SegmentWriter.segmentDuration = 300
        defer { SegmentWriter.segmentDuration = previousDuration }

        let root = try makeTempDirectory("naming-travel")
        defer { try? FileManager.default.removeItem(at: root) }

        let kolkataZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let aucklandZone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        let currentZone = LockedValue<TimeZone>(kolkataZone)
        let readCount = LockedCounter()
        let zoneSource = CaptureZoneSource {
            readCount.increment()
            return currentZone.current
        }

        let time1 = try Self.isoDate("2026-09-29T18:20:00Z")
        let time2 = try Self.isoDate("2026-09-29T18:25:00Z")
        let currentTime = LockedValue<Date>(time1)

        let queue = RemixQueue()
        let storage = StorageManager(baseDirectory: root)
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { NoopRecovery() })
        let manager = CaptureManager(
            storageManager: storage,
            segmentFactory: { dir, prefix, _, _ in NamingCaptureSegment(outputDirectory: dir, timePrefix: prefix) },
            recoveryCoordinator: coordinator,
            finalizer: queue,
            captureZoneSource: zoneSource,
            now: { currentTime.current },
            allowsEmptyDisplayConfigurationForTesting: true,
            microphoneDevices: { [] }
        )

        let seedDir = root.appendingPathComponent("seed.incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
        manager.seedRecordingForTesting(currentSegment: SeedCaptureSegment(outputDirectory: seedDir), sources: .screen)

        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        let rotateOutcome = await executor.enqueue(.rotate(reason: .boundary))
        guard case .committed = rotateOutcome else {
            Issue.record("expected rotate to commit")
            return
        }

        currentZone.set(aucklandZone)

        let pauseOutcome = await executor.enqueue(.pause(reason: .user, stopAudio: true))
        guard case .committed = pauseOutcome else {
            Issue.record("expected pause to commit")
            return
        }
        await queue.waitForCompletion()

        let seg1Dir = root.appendingPathComponent("2026-09-29/235000_300", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: seg1Dir.path))
        let seg1ZoneURL = seg1Dir.appendingPathComponent(StorageManager.captureZoneFileName)
        let seg1ZoneBytesBeforeResume = try Data(contentsOf: seg1ZoneURL)

        currentTime.set(time2)

        let resumeOutcome = await executor.enqueue(.resume(reason: .user))
        guard case .committed = resumeOutcome else {
            Issue.record("expected resume to commit")
            return
        }

        let stopOutcome = await executor.enqueue(.stop(reason: .user))
        guard case .committed = stopOutcome else {
            Issue.record("expected stop to commit")
            return
        }
        await queue.waitForCompletion()

        let seg2Dir = root.appendingPathComponent("2026-09-30/072500_300", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: seg2Dir.path))

        #expect(try Data(contentsOf: seg1ZoneURL) == seg1ZoneBytesBeforeResume)

        let meta1 = SyncService.applyingCaptureTimeZone(segmentURL: seg1Dir, sidecar: .missing)
        guard case .present(let dict1) = meta1 else {
            Issue.record("expected present metadata for seg1")
            return
        }
        #expect(dict1["tz"] == .string("Asia/Kolkata"))
        #expect(dict1["utc_offset_seconds"] == .integer(19800))

        let meta2 = SyncService.applyingCaptureTimeZone(segmentURL: seg2Dir, sidecar: .missing)
        guard case .present(let dict2) = meta2 else {
            Issue.record("expected present metadata for seg2")
            return
        }
        #expect(dict2["tz"] == .string("Pacific/Auckland"))
        #expect(dict2["utc_offset_seconds"] == .integer(46800))

        let syncService = SyncService(
            storageManager: storage,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:9") }
        )
        let snapshot = await syncService.discover()
        let candidates29 = snapshot.candidatesByDay["20260929"] ?? []
        #expect(candidates29.contains { $0.segmentURL.lastPathComponent == "235000_300" })
        let candidates30 = snapshot.candidatesByDay["20260930"] ?? []
        #expect(candidates30.contains { $0.segmentURL.lastPathComponent == "072500_300" })

        #expect(readCount.count == 2)
    }

    @Test func readCount() async throws {
        let previousDuration = SegmentWriter.segmentDuration
        SegmentWriter.segmentDuration = 300
        defer { SegmentWriter.segmentDuration = previousDuration }

        let root = try makeTempDirectory("naming-read-count")
        defer { try? FileManager.default.removeItem(at: root) }

        let tokyoZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let readCount = LockedCounter()
        let zoneSource = CaptureZoneSource {
            readCount.increment()
            return tokyoZone
        }

        let queue = RemixQueue()
        let storage = StorageManager(baseDirectory: root)
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { NoopRecovery() })

        let manager = CaptureManager(
            storageManager: storage,
            segmentFactory: { dir, prefix, _, _ in NamingCaptureSegment(outputDirectory: dir, timePrefix: prefix) },
            recoveryCoordinator: coordinator,
            finalizer: queue,
            captureZoneSource: zoneSource,
            allowsEmptyDisplayConfigurationForTesting: true,
            microphoneDevices: { [] }
        )

        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        let startOutcome = await executor.enqueue(.start(reason: .user, sources: .screen, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = startOutcome else {
            Issue.record("expected start to commit")
            return
        }

        let rotateOutcome = await executor.enqueue(.rotate(reason: .boundary))
        guard case .committed = rotateOutcome else {
            Issue.record("expected rotate to commit")
            return
        }

        let pauseOutcome = await executor.enqueue(.pause(reason: .user, stopAudio: true))
        guard case .committed = pauseOutcome else {
            Issue.record("expected pause to commit")
            return
        }

        let resumeOutcome = await executor.enqueue(.resume(reason: .user))
        guard case .committed = resumeOutcome else {
            Issue.record("expected resume to commit")
            return
        }

        let stopOutcome = await executor.enqueue(.stop(reason: .user))
        guard case .committed = stopOutcome else {
            Issue.record("expected stop to commit")
            return
        }
        await queue.waitForCompletion()

        _ = await IncompleteSegmentRecovery(capturesDirectory: root, finalizer: queue).recoverAll()
        let syncService = SyncService(
            storageManager: storage,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:9") }
        )
        let snapshot = await syncService.discover()
        let allCandidates = snapshot.candidatesByDay.values.flatMap { $0 }
        #expect(!allCandidates.isEmpty)
        for candidate in allCandidates {
            _ = SyncService.applyingCaptureTimeZone(segmentURL: candidate.segmentURL, sidecar: .missing)
        }

        #expect(readCount.count == 3)
    }

    @Test func chainedBump() throws {
        let root = try makeTempDirectory("naming-chained-bump")
        defer { try? FileManager.default.removeItem(at: root) }

        let dayDir = root.appendingPathComponent("2026-10-25", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir.appendingPathComponent("023000_300"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dayDir.appendingPathComponent("023001.failed"), withIntermediateDirectories: true)

        let storage = StorageManager(baseDirectory: root)
        let berlinZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let startInstant = try Self.isoDate("2026-10-25T01:30:00Z")

        let (url, prefix) = try storage.createSegmentDirectory(segmentStartTime: startInstant, timeZone: berlinZone)
        #expect(prefix == "023002")
        #expect(url.lastPathComponent == "023002.incomplete")
    }

    @Test func midnight() async throws {
        let previousDuration = SegmentWriter.segmentDuration
        SegmentWriter.segmentDuration = 300
        defer { SegmentWriter.segmentDuration = previousDuration }

        let root = try makeTempDirectory("naming-midnight")
        defer { try? FileManager.default.removeItem(at: root) }

        let dec31Dir = root.appendingPathComponent("2026-12-31", isDirectory: true)
        try FileManager.default.createDirectory(at: dec31Dir.appendingPathComponent("235959_300"), withIntermediateDirectories: true)

        let storage = StorageManager(baseDirectory: root)
        let kolkataZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let startInstant = try Self.isoDate("2026-12-31T18:29:59Z")

        let (url, prefix) = try storage.createSegmentDirectory(segmentStartTime: startInstant, timeZone: kolkataZone)
        #expect(prefix == "000000")
        #expect(url.deletingLastPathComponent().lastPathComponent == "2027-01-01")
        #expect(url.lastPathComponent == "000000.incomplete")

        let mediaURL = url.appendingPathComponent("\(prefix)_display_1_screen.mp4")
        try Data("screen-bytes".utf8).write(to: mediaURL)

        let queue = RemixQueue()
        let job = RemixQueue.RemixJob(
            segmentDirectory: url,
            timePrefix: prefix,
            capturedDurationSeconds: 300,
            audioInputs: [],
            silenceMusic: true,
            micMetadataJSON: nil
        )
        await queue.enqueue(job)
        await queue.waitForCompletion()

        let finalDir = root.appendingPathComponent("2027-01-01/000000_300", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: finalDir.path))

        let syncService = SyncService(
            storageManager: storage,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:9") }
        )
        let snapshot = await syncService.discover()
        let candidates = snapshot.candidatesByDay["20270101"] ?? []
        #expect(candidates.contains { $0.segmentURL.lastPathComponent == "000000_300" })

        let zoneURL = finalDir.appendingPathComponent(StorageManager.captureZoneFileName)
        let zoneData = try Data(contentsOf: zoneURL)
        let zoneDict = try JSONSerialization.jsonObject(with: zoneData) as? [String: Any]
        #expect(zoneDict?["utc_offset_seconds"] as? Int == 19800)
    }

    @Test func springForward() throws {
        let root = try makeTempDirectory("naming-spring-forward")
        defer { try? FileManager.default.removeItem(at: root) }

        let dayDir = root.appendingPathComponent("2026-03-29", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir.appendingPathComponent("015959.incomplete"), withIntermediateDirectories: true)

        let storage = StorageManager(baseDirectory: root)
        let berlinZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let startInstant = try Self.isoDate("2026-03-29T00:59:59Z")

        let (url, prefix) = try storage.createSegmentDirectory(segmentStartTime: startInstant, timeZone: berlinZone)
        #expect(prefix == "020000")
        #expect(url.deletingLastPathComponent().lastPathComponent == "2026-03-29")
        #expect(url.lastPathComponent == "020000.incomplete")

        let zoneURL = url.appendingPathComponent(StorageManager.captureZoneFileName)
        let zoneData = try Data(contentsOf: zoneURL)
        let zoneDict = try JSONSerialization.jsonObject(with: zoneData) as? [String: Any]
        #expect(zoneDict?["utc_offset_seconds"] as? Int == 3600)
    }

    @Test func freeStem() throws {
        let root = try makeTempDirectory("naming-free-stem")
        defer { try? FileManager.default.removeItem(at: root) }

        let prevDayDir = root.appendingPathComponent("2026-01-14", isDirectory: true)
        try FileManager.default.createDirectory(at: prevDayDir.appendingPathComponent("120000_300"), withIntermediateDirectories: true)

        let storage = StorageManager(baseDirectory: root)
        let kolkataZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let startInstant = try Self.isoDate("2026-01-15T06:30:00Z")

        let (url, prefix) = try storage.createSegmentDirectory(segmentStartTime: startInstant, timeZone: kolkataZone)
        #expect(prefix == "120000")
        #expect(url.deletingLastPathComponent().lastPathComponent == "2026-01-15")
        #expect(url.lastPathComponent == "120000.incomplete")
    }

    @Test func exclusiveCreateBackstop() throws {
        let root = try makeTempDirectory("naming-exclusive-backstop")
        defer { try? FileManager.default.removeItem(at: root) }

        let hookCalls = LockedCounter()
        struct HookError: Error {}
        let storage = StorageManager(
            baseDirectory: root,
            listDirectoryContents: { _ in
                hookCalls.increment()
                throw HookError()
            }
        )

        let kolkataZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let startInstant = try Self.isoDate("2026-01-15T06:30:00Z")

        let (firstURL, firstPrefix) = try storage.createSegmentDirectory(segmentStartTime: startInstant, timeZone: kolkataZone)
        #expect(firstPrefix == "120000")
        #expect(hookCalls.count == 0)

        let mediaFile = firstURL.appendingPathComponent("120000_screen.mp4")
        try Data("first-media".utf8).write(to: mediaFile)
        let zoneURL = firstURL.appendingPathComponent(StorageManager.captureZoneFileName)
        let savedZone = try Data(contentsOf: zoneURL)
        let savedMedia = try Data(contentsOf: mediaFile)

        #expect(throws: (any Error).self) {
            try storage.createSegmentDirectory(segmentStartTime: startInstant, timeZone: kolkataZone)
        }
        #expect(hookCalls.count == 1)

        #expect(try Data(contentsOf: mediaFile) == savedMedia)
        #expect(try Data(contentsOf: zoneURL) == savedZone)

        let dayDir = root.appendingPathComponent("2026-01-15", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dayDir.path)
        #expect(entries == ["120000.incomplete"])
    }

    @Test func olderEntries() async throws {
        let previousDuration = SegmentWriter.segmentDuration
        SegmentWriter.segmentDuration = 300
        defer { SegmentWriter.segmentDuration = previousDuration }

        let root = try makeTempDirectory("naming-older-entries")
        defer { try? FileManager.default.removeItem(at: root) }

        let dayDir = root.appendingPathComponent("2026-10-25", isDirectory: true)
        let finalizedDir = dayDir.appendingPathComponent("023000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: finalizedDir, withIntermediateDirectories: true)

        let finalizedMedia = finalizedDir.appendingPathComponent("023000_300_display_1_screen.mp4")
        try Data("finalized-media".utf8).write(to: finalizedMedia)
        let finalizedZone = finalizedDir.appendingPathComponent(StorageManager.captureZoneFileName)
        try Data("{\"tz\":\"Europe/Berlin\",\"utc_offset_seconds\":7200}".utf8).write(to: finalizedZone)

        let savedFinalizedMedia = try Data(contentsOf: finalizedMedia)
        let savedFinalizedZone = try Data(contentsOf: finalizedZone)

        let incDir = dayDir.appendingPathComponent("023000.incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: incDir, withIntermediateDirectories: true)
        let incMedia = incDir.appendingPathComponent("023000_display_1_screen.mp4")
        let incMediaBytes = Data("incomplete-media-bytes".utf8)
        try incMediaBytes.write(to: incMedia)

        let oldDate = Date().addingTimeInterval(-500)
        try FileManager.default.setAttributes([.creationDate: oldDate], ofItemAtPath: incDir.path)

        let queue = RemixQueue(durationLoader: { _ in CMTime(seconds: 300, preferredTimescale: 600) })
        let recovery = IncompleteSegmentRecovery(capturesDirectory: root, finalizer: queue)
        let recovered = await recovery.recoverAll()
        #expect(recovered == 1)
        await queue.waitForCompletion()

        #expect(FileManager.default.fileExists(atPath: incDir.path))
        let notFailedDir = dayDir.appendingPathComponent("023000.failed", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: notFailedDir.path))

        let incDirContents = try FileManager.default.contentsOfDirectory(atPath: incDir.path)
        var foundMatchingMedia = false
        for file in incDirContents {
            let fileURL = incDir.appendingPathComponent(file)
            if let data = try? Data(contentsOf: fileURL), data == incMediaBytes {
                foundMatchingMedia = true
                break
            }
        }
        #expect(foundMatchingMedia)

        #expect(try Data(contentsOf: finalizedMedia) == savedFinalizedMedia)
        #expect(try Data(contentsOf: finalizedZone) == savedFinalizedZone)
    }

    @Test func failedZoneRead() async throws {
        let root = try makeTempDirectory("naming-failed-zone-read")
        defer { try? FileManager.default.removeItem(at: root) }

        struct InjectedZoneError: Error {}
        let zoneSource = CaptureZoneSource { throw InjectedZoneError() }

        let queue = RemixQueue()
        let storage = StorageManager(baseDirectory: root)
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { NoopRecovery() })
        let manager = CaptureManager(
            storageManager: storage,
            segmentFactory: { dir, prefix, _, _ in NamingCaptureSegment(outputDirectory: dir, timePrefix: prefix) },
            recoveryCoordinator: coordinator,
            finalizer: queue,
            captureZoneSource: zoneSource,
            allowsEmptyDisplayConfigurationForTesting: true,
            microphoneDevices: { [] }
        )

        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        let startOutcome = await executor.enqueue(.start(reason: .user, sources: .screen, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = startOutcome else {
            Issue.record("expected start to commit")
            return
        }

        let stopOutcome = await executor.enqueue(.stop(reason: .user))
        guard case .committed = stopOutcome else {
            Issue.record("expected stop to commit")
            return
        }
        await queue.waitForCompletion()

        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            Issue.record("could not enumerate root")
            return
        }

        var foundSegmentDir = false
        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.lastPathComponent == StorageManager.captureZoneFileName {
                Issue.record("capture_zone.json should not exist when zone read fails")
            }
            if fileURL.lastPathComponent.contains("_300") || fileURL.lastPathComponent.contains(".incomplete") {
                foundSegmentDir = true
            }
        }
        #expect(foundSegmentDir)
    }
}
