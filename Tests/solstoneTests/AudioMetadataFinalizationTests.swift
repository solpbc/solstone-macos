// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import Testing
@testable import solstone

@Suite("AudioMetadataFinalization")
struct AudioMetadataFinalizationTests {
    @Test(arguments: [false, true])
    func retryUpdatesCopyDispositionWithoutGrantingPartialCleanup(complete: Bool) async throws {
        let root = try makeTempDirectory("audio-metadata-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("120000_audio_mic.m4a")
        try Data("recoverable original".utf8).write(to: raw)
        let previous: [String: Any] = [
            "unreadable_audio_sources": ["count": 1, "source_ids": ["mic"]],
            "audio_capture": ["version": 1, "state": "interrupted", "remix": [["source_id": "mic", "state": "unreadable", "stage": "reader"]]],
        ]
        try JSONSerialization.data(withJSONObject: previous).write(to: dir.appendingPathComponent("120000_meta.json"))
        let disposition = AudioSourceRemixResult(sourceID: "mic", state: complete ? "complete" : "partial", stage: complete ? nil : "reader", framesCopied: 960)
        let result = AudioRemixerResult(tracksWritten: 1, tracksSkipped: 0, sourceFiles: complete ? [raw] : [], sources: [disposition])
        let queue = RemixQueue { _ in MetadataResultRemixer(result: result) }
        await queue.enqueue(job(dir: dir, inputs: [input(raw)]))
        await queue.waitForCompletion()
        let final = root.appendingPathComponent("120000_1")
        let meta = try metadata(final.appendingPathComponent("120000_1_meta.json"))
        #expect(meta["unreadable_audio_sources"] == nil)
        let capture = try #require(meta["audio_capture"] as? [String: Any])
        #expect(capture["state"] as? String == "interrupted")
        let remix = try #require((capture["remix"] as? [[String: Any]])?.first)
        #expect(remix["state"] as? String == (complete ? "complete" : "partial"))
        #expect((remix["prior_outcome"] as? [String: Any])?["state"] as? String == "unreadable")
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("120000_1_audio_mic.m4a").path) == !complete)
    }

    @Test func metadataWriteFailureKeepsFullyRemixedRaw() async throws {
        let root = try makeTempDirectory("audio-metadata-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("120000_meta.json"), withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("120000_audio_mic.m4a")
        try Data("original".utf8).write(to: raw)
        let result = AudioRemixerResult(tracksWritten: 1, tracksSkipped: 0, sourceFiles: [raw],
            sources: [AudioSourceRemixResult(sourceID: "mic", state: "complete", framesCopied: 960)])
        let queue = RemixQueue { _ in MetadataResultRemixer(result: result) }
        await queue.enqueue(job(dir: dir, inputs: [input(raw)]))
        await queue.waitForCompletion()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed/120000_audio_mic.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("120000_1").path))
    }

    @Test func interruptedSidecarsMergeIntoOneWithoutErasingPartialEvidence() async throws {
        let root = try makeTempDirectory("audio-metadata-sidecars")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("already consolidated".utf8).write(to: dir.appendingPathComponent("120000_audio.m4a"))
        for (name, capture) in [
            ("120000_meta.json", ["version": 1, "state": "recording", "sources": [["source_id": "mic", "state": "recording", "accepted_frames": 0]]] as [String: Any]),
            ("120000_1_meta.json", ["version": 1, "state": "partial", "remix": [["source_id": "mic", "state": "partial"]], "sources": [["source_id": "mic", "state": "partial", "accepted_frames": 960, "failures": [["stage": "append", "domain": "test", "code": 1]]]]] as [String: Any]),
        ] {
            var root: [String: Any] = ["audio_capture": capture]
            if name == "120000_meta.json" { root["unreadable_audio_sources"] = ["count": 1, "source_ids": ["mic"]] }
            try JSONSerialization.data(withJSONObject: root).write(to: dir.appendingPathComponent(name))
        }
        try Data("recoverable partial".utf8).write(to: dir.appendingPathComponent("120000_audio_mic.m4a"))
        let queue = RemixQueue()
        await queue.enqueue(job(dir: dir, inputs: []))
        await queue.waitForCompletion()
        let final = root.appendingPathComponent("120000_1")
        let meta = try metadata(final.appendingPathComponent("120000_1_meta.json"))
        #expect(meta["unreadable_audio_sources"] == nil)
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("120000_1_audio_mic.m4a").path))
        let capture = try #require(meta["audio_capture"] as? [String: Any])
        #expect(capture["state"] as? String == "partial")
        #expect((capture["sources"] as? [[String: Any]])?.first?["state"] as? String == "partial")
        #expect((capture["sources"] as? [[String: Any]])?.first?["accepted_frames"] as? Int == 960)
        #expect(!FileManager.default.fileExists(atPath: final.appendingPathComponent("120000_meta.json").path))
    }

    private func metadata(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func input(_ url: URL) -> AudioRemixerInput {
        AudioRemixerInput(url: url, timingInfo: AudioTrackTimingInfo(startOffset: .zero, endOffset: CMTime(seconds: 1, preferredTimescale: 48_000), trackType: .microphone(name: "mic", deviceUID: "mic")))
    }
    private func job(dir: URL, inputs: [AudioRemixerInput]) -> RemixQueue.RemixJob {
        .init(segmentDirectory: dir, timePrefix: "120000", capturedDurationSeconds: 1, audioInputs: inputs, silenceMusic: false, micMetadataJSON: nil)
    }
}

private struct MetadataResultRemixer: AudioRemixing {
    let result: AudioRemixerResult
    func remix(inputs: [AudioRemixerInput], to outputURL: URL, silenceMusic: Bool) async throws -> AudioRemixerResult {
        try Data("completed output".utf8).write(to: outputURL)
        return result
    }
}
