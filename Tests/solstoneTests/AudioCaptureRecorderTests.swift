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
            droppedFrames: 960, writerStatus: "completed", failures: [.init(stage: "append", domain: "test", code: 8, count: 2)]))
        recorder.failure("mic", stage: "start", error: NSError(domain: "test", code: 9))
        try recorder.seal()
        let terminal = try read(root)
        #expect(terminal["state"] as? String == "partial")
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
        sourceProperties["writer_status"] = ["enum": ["recording", "completed", "failed", "no_audio"]]
        let failure = (source["failures"] as? [[String: Any]])!.first!
        sourceProperties["failures"] = ["type": "array", "maxItems": AudioCaptureRecorder.failureLimit,
            "items": ["type": "object", "required": failure.keys.sorted(), "properties": fields(failure)]]
        properties["sources"] = ["type": "array", "maxItems": AudioCaptureRecorder.sourceLimit,
            "items": ["type": "object", "required": source.keys.sorted(), "properties": sourceProperties]]
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
