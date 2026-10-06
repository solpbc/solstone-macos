// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

/// Segment-local evidence. Audio callbacks only update memory; checkpoints run
/// on a serial queue. Sealing drains that queue before finalization can proceed.
public final class AudioCaptureRecorder: @unchecked Sendable {
    public static let sourceLimit = 32
    public static let failureLimit = 16

    private struct Source: Encodable {
        let source_id: String
        let kind: String
        var expected = true
        var started = false
        var state = "recording"
        var received_frames = 0
        var accepted_frames = 0
        var dropped_frames = 0
        var writer_status = "recording"
        var statistics_available: Bool?
        var statistics_complete: Bool?
        var timeline_origin_seconds: Double?
        var generated_frames: Int?
        var gap_count: Int?
        var failures: [AudioRecordingFailure] = []
    }
    private struct Capture: Encodable {
        let version = 1
        let timeline_version = 1
        var state = "recording"
        let app_version: String
        let app_build: String
        var sources: [Source] = []
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.solstone.audio.evidence", qos: .utility)
    private let metadataURL: URL
    private let segmentID: String
    private var capture: Capture
    private var sealed = false
    private var handedOff = false
    private let onFirstFailure: (@Sendable () -> Void)?
    private var notified = false
#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal var _persistenceHookForTesting: (@Sendable () -> Void)?
#endif

    public init(directory: URL, timePrefix: String, expected: [(id: String, kind: String)],
                appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                onFirstFailure: (@Sendable () -> Void)? = nil) throws {
        self.onFirstFailure = onFirstFailure
        metadataURL = directory.appendingPathComponent("\(timePrefix)_meta.json")
        segmentID = timePrefix
        capture = Capture(app_version: appVersion, app_build: appBuild)
        for source in expected.prefix(Self.sourceLimit) where !capture.sources.contains(where: { $0.source_id == source.id }) {
            capture.sources.append(Source(source_id: source.id, kind: source.kind))
        }
        if expected.count > Self.sourceLimit { capture.state = "partial" }
        try persist(capture)
    }

    public func expect(_ id: String, kind: String) {
        lock.withLock {
            guard !sealed, !capture.sources.contains(where: { $0.source_id == id }) else { return }
            guard capture.sources.count < Self.sourceLimit else { capture.state = "partial"; checkpoint(); return }
            capture.sources.append(Source(source_id: id, kind: kind))
            checkpoint()
        }
    }

    public func started(_ id: String) {
        lock.withLock {
            guard !sealed, let index = index(id) else { return }
            capture.sources[index].started = true
            checkpoint()
        }
    }

    /// Required origin is durable before AVAssetWriter can create a recoverable
    /// prefix, including microphones added after the segment has started.
    public func admitSource(_ id: String, kind: String) throws {
        try lock.withLock {
            guard !sealed, !handedOff else { throw NSError(domain: "SolstoneAudioOrigin", code: 1) }
            if index(id) == nil {
                guard capture.sources.count < Self.sourceLimit else { throw NSError(domain: "SolstoneAudioOrigin", code: 2) }
                capture.sources.append(Source(source_id: id, kind: kind))
            }
            capture.sources[index(id)!].timeline_origin_seconds = 0
            do { try queue.sync { try persist(capture) } }
            catch {
                addFailure(index(id)!, AudioRecordingFailure(stage: "origin", domain: "SolstoneAudioOrigin", code: 3))
                throw error
            }
        }
    }

    public func failure(_ id: String, stage: String, error: Error) {
        let native = error as NSError
        lock.withLock {
            guard !sealed, let index = index(id) else { return }
            addFailure(index, AudioRecordingFailure(stage: stage, domain: String(native.domain.prefix(128)), code: native.code))
        }
    }

    public func finishFailure(_ error: Error) {
        lock.withLock {
            guard !handedOff else { return }
            let native = error as NSError
            if capture.state != "failed" { capture.state = "partial" }
            for index in capture.sources.indices {
                addFailure(index, AudioRecordingFailure(stage: "finish", domain: String(native.domain.prefix(128)), code: native.code))
            }
            checkpoint()
        }
    }

    public func statistics(_ id: String, _ statistics: AudioWriterStatistics) {
        lock.withLock {
            guard !handedOff, let index = index(id) else { return }
            let old = capture.sources[index]
            var oldValues: [String: Any] = ["received_frames": old.received_frames, "accepted_frames": old.accepted_frames, "dropped_frames": old.dropped_frames]
            if let value = old.statistics_available { oldValues["statistics_available"] = value }
            if let value = old.statistics_complete { oldValues["statistics_complete"] = value }
            if let value = old.generated_frames { oldValues["generated_frames"] = value }
            if let value = old.gap_count { oldValues["gap_count"] = value }
            var newValues: [String: Any] = ["received_frames": statistics.receivedFrames, "accepted_frames": statistics.acceptedFrames, "dropped_frames": statistics.droppedFrames]
            if let value = statistics.statisticsAvailable { newValues["statistics_available"] = value }
            if let value = statistics.statisticsComplete { newValues["statistics_complete"] = value }
            if let value = statistics.generatedFrames { newValues["generated_frames"] = value }
            if let value = statistics.gapCount { newValues["gap_count"] = value }
            let flags = mergeAudioStatisticsFlags(oldValues, newValues)
            capture.sources[index].received_frames = max(old.received_frames, statistics.receivedFrames)
            capture.sources[index].accepted_frames = max(old.accepted_frames, statistics.acceptedFrames)
            capture.sources[index].dropped_frames = max(old.dropped_frames, statistics.droppedFrames)
            if old.generated_frames != nil || statistics.generatedFrames != nil {
                capture.sources[index].generated_frames = max(old.generated_frames ?? 0, statistics.generatedFrames ?? 0)
            }
            if old.gap_count != nil || statistics.gapCount != nil {
                capture.sources[index].gap_count = max(old.gap_count ?? 0, statistics.gapCount ?? 0)
            }
            capture.sources[index].statistics_available = flags["statistics_available"]
            capture.sources[index].statistics_complete = flags["statistics_complete"]
            if old.statistics_complete != true || statistics.statisticsComplete == true || flags["statistics_complete"] != true {
                capture.sources[index].writer_status = statistics.writerStatus
            }
            for failure in statistics.failures {
                if let old = capture.sources[index].failures.firstIndex(where: {
                    $0.stage == failure.stage && $0.domain == failure.domain && $0.code == failure.code
                }) {
                    capture.sources[index].failures[old].count = max(capture.sources[index].failures[old].count, failure.count)
                } else { addFailure(index, failure) }
            }
            if statistics.droppedFrames > 0 || statistics.writerStatus == "failed" {
                capture.sources[index].state = "partial"
                if capture.state != "failed" { capture.state = "partial" }
            }
            if sealed {
                terminalSource(index)
                checkpoint()
            }
        }
    }

    /// Terminal persistence is a gate: failure leaves the local segment recoverable.
    public func seal(failed: Bool = false) throws {
        try lock.withLock {
            guard !handedOff else { return }
            sealed = true
            if failed { capture.state = "failed" }
            else if capture.state == "recording" { capture.state = "finished" }
            for index in capture.sources.indices { terminalSource(index) }
            if capture.state == "finished", capture.sources.contains(where: { $0.state == "unknown" }) { capture.state = "unknown" }
            try queue.sync { try persist(capture) }
            Logger.audio.notice("Audio segment \(self.segmentID, privacy: .public): \(self.capture.state, privacy: .public), sources \(self.capture.sources.count, privacy: .public)")
        }
    }

    /// Close callback admission, then drain/persist before the finalizer reads,
    /// merges or renames the sidecar. Late callbacks cannot recreate its old path.
    public func handoff() throws {
        let snapshot = lock.withLock { () -> Capture? in
            guard !handedOff else { return nil }
            handedOff = true
            return capture
        }
        guard let snapshot else { return }
        try queue.sync { try persist(snapshot) }
    }

    private func terminalSource(_ index: Int) {
        if capture.sources[index].statistics_available == nil { capture.sources[index].statistics_available = false }
        if capture.sources[index].statistics_complete != true {
            capture.sources[index].statistics_complete = false
            capture.sources[index].writer_status = "unknown"
        }
        if ["recording", "unknown"].contains(capture.sources[index].state) {
            capture.sources[index].state = capture.sources[index].statistics_complete == true
                && ["completed", "no_audio"].contains(capture.sources[index].writer_status) ? "finished" : "unknown"
        }
    }

    private func index(_ id: String) -> Int? { capture.sources.firstIndex { $0.source_id == id } }

    /// Called under the bookkeeping lock; enqueueing here preserves checkpoint order.
    private func checkpoint() {
        let snapshot = capture
        queue.async { [self] in
            do { try persist(snapshot) }
            catch { Logger.audio.error("Audio segment \(self.segmentID, privacy: .public): metadata checkpoint failed") }
        }
    }

    /// Sources whose audio in this segment has a real gap. A disconnect is the owner
    /// unplugging a device and is recorded, but it is not a loss to alarm about.
    public func sourcesWithLoss() -> [String] {
        lock.withLock {
            capture.sources.filter { $0.failures.contains { $0.stage != "disconnect" } }.map(\.source_id)
        }
    }

    private func addFailure(_ index: Int, _ failure: AudioRecordingFailure) {
        if capture.state != "failed" { capture.state = "partial" }
        capture.sources[index].state = "partial"
        if !notified { notified = true; onFirstFailure?() }
        if let existing = capture.sources[index].failures.firstIndex(where: {
            $0.stage == failure.stage && $0.domain == failure.domain && $0.code == failure.code
        }) { capture.sources[index].failures[existing].count += failure.count }
        else if capture.sources[index].failures.count < Self.failureLimit {
            capture.sources[index].failures.append(failure)
            Logger.audio.notice("Audio segment \(self.segmentID, privacy: .public), \(self.capture.sources[index].kind, privacy: .public): \(failure.stage, privacy: .public), code \(failure.code, privacy: .public)")
            checkpoint()
        }
    }

    private func persist(_ capture: Capture) throws {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        _persistenceHookForTesting?()
#endif
        let encoded = try JSONEncoder().encode(capture)
        let value = try JSONSerialization.jsonObject(with: encoded)
        var metadata: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let existing = try Data(contentsOf: metadataURL)
            guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw NSError(domain: "SolstoneAudioMetadata", code: 1)
            }
            metadata = object
        }
        metadata["audio_capture"] = value
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: metadataURL, options: .atomic)
    }
}
