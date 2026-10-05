// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreFoundation
import Testing
@testable import solstone

@Suite("AudioCaptureEvidence")
struct AudioCaptureRecorderTests {
    @Test func intentFailureCountersAndSealedCallbacksMatchWireFixture() throws {
        let root = try makeTempDirectory("audio-capture-evidence")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000",
            expected: [("system", "system"), ("mic", "microphone")], appVersion: "test", appBuild: "1")
        let initial = try read(root)
        #expect(initial["state"] as? String == "recording")
        #expect((initial["sources"] as? [[String: Any]])?.count == 2)
        recorder.started("system")
        for _ in 0..<3 { recorder.failure("system", stage: "capture", error: NSError(domain: "test", code: 7)) }
        recorder.statistics("system", AudioWriterStatistics(receivedFrames: 1920, acceptedFrames: 960,
            droppedFrames: 960, writerStatus: "completed", failures: [.init(stage: "append", domain: "test", code: 8, count: 2)], statisticsAvailable: true, statisticsComplete: true))
        recorder.failure("mic", stage: "start", error: NSError(domain: "test", code: 9))
        try recorder.seal()
        let terminal = try read(root)
        #expect(terminal["state"] as? String == "partial")
        try recorder.handoff()
        recorder.failure("system", stage: "late", error: NSError(domain: "test", code: 10))
        recorder.statistics("system", AudioWriterStatistics())
        #expect(NSDictionary(dictionary: try read(root)) == NSDictionary(dictionary: terminal))

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("contracts/audio-capture-v1.example.json")
        let data = try JSONSerialization.data(withJSONObject: ["audio_capture": terminal], options: [.prettyPrinted, .sortedKeys])
        let schemaURL = fixture.deletingLastPathComponent().appendingPathComponent("audio-capture-v1.schema.json")
        let schema = try contractSchema(terminal)
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
        if ProcessInfo.processInfo.environment["SOLSTONE_WRITE_AUDIO_CAPTURE_FIXTURE"] == "1" {
            try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fixture)
            try schemaData.write(to: schemaURL)
        }
        let committed = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any]
        #expect(NSDictionary(dictionary: committed ?? [:]) == NSDictionary(dictionary: ["audio_capture": terminal]))
        let committedSchema = try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
        #expect(NSDictionary(dictionary: committedSchema ?? [:]) == NSDictionary(dictionary: schema))
    }

    @Test func lateCompletionImprovesCountsUntilHandoffAndNeverRecreatesOldPath() throws {
        let root = try makeTempDirectory("audio-evidence-handoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [("system", "system")])
        recorder.statistics("system", AudioWriterStatistics(receivedFrames: 960, acceptedFrames: 480,
            statisticsAvailable: true, statisticsComplete: false))
        recorder.finishFailure(NSError(domain: "timeout", code: 1))
        try recorder.seal()
        let before = try #require((try read(root)["sources"] as? [[String: Any]])?.first)
        #expect(before["received_frames"] as? Int == 960)
        #expect(before["accepted_frames"] as? Int == 480)
        #expect(before["writer_status"] as? String == "unknown")
        #expect(before["statistics_available"] as? Bool == true)
        #expect(before["statistics_complete"] as? Bool == false)
        recorder.statistics("system", AudioWriterStatistics(receivedFrames: 960, acceptedFrames: 960,
            writerStatus: "completed", statisticsAvailable: true, statisticsComplete: true))
        try recorder.handoff()
        let after = try read(root)
        let source = try #require((after["sources"] as? [[String: Any]])?.first)
        #expect(source["accepted_frames"] as? Int == 960)
        #expect(source["statistics_complete"] as? Bool == true)
        #expect(source["writer_status"] as? String == "completed")
        #expect(source["state"] as? String == "partial" && after["state"] as? String == "partial")
        #expect((source["failures"] as? [[String: Any]])?.first?["stage"] as? String == "finish")
        let meta = root.appendingPathComponent("120000_meta.json")
        let finalMeta = root.appendingPathComponent("120000_1_meta.json")
        try FileManager.default.moveItem(at: meta, to: finalMeta)
        let frozen = try Data(contentsOf: finalMeta)
        recorder.statistics("system", AudioWriterStatistics(receivedFrames: 1920, acceptedFrames: 1920))
        try recorder.handoff()
        #expect(!FileManager.default.fileExists(atPath: meta.path))
        #expect(try Data(contentsOf: finalMeta) == frozen)
    }

    @Test func verifiedZeroAndUnavailableZeroHaveDifferentEvidence() throws {
        let root = try makeTempDirectory("audio-evidence-zero")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [("system", "system"), ("mic", "microphone")])
        recorder.statistics("system", AudioWriterStatistics(writerStatus: "no_audio", statisticsAvailable: true, statisticsComplete: true))
        try recorder.seal()
        let sources = try #require(try read(root)["sources"] as? [[String: Any]])
        #expect(sources[0]["state"] as? String == "finished" && sources[0]["statistics_complete"] as? Bool == true)
        #expect(sources[1]["state"] as? String == "unknown" && sources[1]["statistics_available"] as? Bool == false)
        #expect(sources[1]["writer_status"] as? String == "unknown")
    }

    @Test func mergeDoesNotBlessLargerLowerBoundsOrDuplicateFailures() {
        let failure: [String: Any] = ["stage": "finish", "domain": "timeout", "code": 1, "count": 1]
        let complete: [String: Any] = ["source_id": "system", "state": "partial", "received_frames": 480,
            "accepted_frames": 480, "dropped_frames": 0, "statistics_available": true, "statistics_complete": true,
            "writer_status": "completed", "failures": [failure]]
        let lower: [String: Any] = ["source_id": "system", "state": "unknown", "received_frames": 960,
            "accepted_frames": 480, "dropped_frames": 0, "statistics_available": true, "statistics_complete": false,
            "writer_status": "unknown", "failures": [failure]]
        let merged = mergeAudioCaptureMetadata(["state": "partial", "sources": [complete]], ["state": "finished", "sources": [lower]])
        let source = (merged["sources"] as! [[String: Any]])[0]
        #expect(source["statistics_complete"] as? Bool == false)
        #expect(source["received_frames"] as? Int == 960 && source["state"] as? String == "partial")
        #expect((source["failures"] as? [[String: Any]])?.count == 1)
        #expect(merged["state"] as? String == "partial")
    }

    @Test func terminalFailureSurvivesLateStatisticsAndBoundedMerge() throws {
        let root = try makeTempDirectory("audio-evidence-terminal-severity")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [("system", "system")])
        try recorder.seal(failed: true)
        recorder.statistics("system", AudioWriterStatistics(receivedFrames: 10, droppedFrames: 10,
            writerStatus: "failed", statisticsAvailable: true, statisticsComplete: true))
        try recorder.handoff()
        #expect(try read(root)["state"] as? String == "failed")
        let merged = mergeAudioCaptureMetadata(["state": "partial", "sources": [["source_id": "system", "state": "partial"]]],
            ["state": "failed", "sources": [["source_id": "system", "state": "failed"]]])
        #expect((merged["sources"] as? [[String: Any]])?.first?["state"] as? String == "failed")
        let rows = (0..<32).map { ["source_id": "mic-\($0)", "state": "finished"] }
        let bounded = mergeAudioCaptureMetadata(["state": "finished", "sources": rows],
            ["state": "finished", "sources": [["source_id": "one-more", "state": "finished"]]])
        #expect((bounded["sources"] as? [[String: Any]])?.count == 32)
        #expect(bounded["state"] as? String == "partial")
    }

    @Test func terminalWriteFailureIsNotSuccess() throws {
        let root = try makeTempDirectory("audio-capture-write-fault")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [("system", "system")])
        let meta = root.appendingPathComponent("120000_meta.json")
        try FileManager.default.removeItem(at: meta)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try recorder.seal() }
    }

    @Test func errorsStayBoundedAndRepeatedFailuresCoalesce() throws {
        let root = try makeTempDirectory("audio-capture-bounds")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [("system", "system")])
        for code in 0..<50 { recorder.failure("system", stage: "capture", error: NSError(domain: "test", code: code)) }
        for _ in 0..<100 { recorder.failure("system", stage: "capture", error: NSError(domain: "test", code: 0)) }
        try recorder.seal()
        let rows = try #require(try read(root)["sources"] as? [[String: Any]])
        let failures = try #require(rows.first?["failures"] as? [[String: Any]])
        #expect(failures.count == AudioCaptureRecorder.failureLimit)
        #expect(failures.first?["count"] as? Int == 101)
    }

    private func read(_ root: URL) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("120000_meta.json"))) as? [String: Any]
        return try #require(value?["audio_capture"] as? [String: Any])
    }

    /// Generate the additive contract from the actual Swift encoders. This is
    /// an evidence-reader contract, never an upload-admission requirement.
    private func contractSchema(_ capture: [String: Any]) throws -> [String: Any] {
        func fields(_ object: [String: Any]) -> [String: Any] {
            object.mapValues { value -> [String: Any] in
                if let number = value as? NSNumber {
                    return ["type": CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "integer"]
                }
                if value is String { return ["type": "string"] }
                if let rows = value as? [[String: Any]] {
                    return ["type": "array", "items": ["type": "object", "properties": fields(rows.first ?? [:])]]
                }
                return ["type": "object"]
            }
        }
        let states = ["recording", "finished", "partial", "failed", "interrupted", "unknown"]
        var properties = fields(capture)
        properties["version"] = ["const": 1]
        properties["state"] = ["enum": states]
        let source = (capture["sources"] as? [[String: Any]])!.first!
        var sourceProperties = fields(source)
        sourceProperties["state"] = ["enum": states]
        sourceProperties["kind"] = ["enum": ["system", "microphone"]]
        sourceProperties["writer_status"] = ["enum": ["recording", "completed", "failed", "no_audio", "unknown"]]
        let failure = (source["failures"] as? [[String: Any]])!.first!
        sourceProperties["failures"] = ["type": "array", "maxItems": AudioCaptureRecorder.failureLimit,
            "items": ["type": "object", "required": failure.keys.sorted(), "properties": fields(failure)]]
        sourceProperties["statistics_available"] = ["type": "boolean"]
        sourceProperties["statistics_complete"] = ["type": "boolean"]
        properties["failures"] = sourceProperties["failures"]
        properties["sources"] = ["type": "array", "maxItems": AudioCaptureRecorder.sourceLimit,
            "items": ["type": "object", "required": ["accepted_frames", "dropped_frames", "expected", "failures", "kind", "received_frames", "source_id", "started", "state", "writer_status"], "properties": sourceProperties]]
        let remix = AudioSourceRemixResult(sourceID: "system", state: "partial", stage: "reader",
            errorDomain: "test", errorCode: 1, framesCopied: 960, musicAnalysis: "unavailable")
        let encodedRemix = try JSONSerialization.jsonObject(with: JSONEncoder().encode(remix)) as! [String: Any]
        var remixProperties = fields(encodedRemix)
        remixProperties["state"] = ["enum": ["complete", "partial", "unreadable", "failed"]]
        let prior: [String: Any] = ["type": "object", "required": ["source_id", "state", "frames_copied"], "properties": remixProperties]
        remixProperties["prior_outcome"] = prior
        properties["remix"] = ["type": "array", "maxItems": AudioCaptureRecorder.sourceLimit,
            "items": ["type": "object", "required": ["source_id", "state", "frames_copied"], "properties": remixProperties]]
        return ["$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object",
            "required": ["version", "state"], "properties": properties]
    }
}
