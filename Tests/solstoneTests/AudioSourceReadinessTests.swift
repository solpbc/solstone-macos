// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("AudioSourceReadiness")
struct AudioSourceReadinessTests {
    @Test func classifyNoSources() async throws {
        let root = try makeTempDirectory("audio-source-readiness-none")
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("video".utf8).write(to: root.appendingPathComponent("120000_screen.mp4"))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)

        let result = await classifyAudioSources(in: files, timePrefix: "120000", verbose: false)

        guard case .noSources = result else {
            Issue.record("Expected noSources")
            return
        }
    }

    @Test func classifyReady() async throws {
        let root = try makeTempDirectory("audio-source-readiness-ready")
        defer { try? FileManager.default.removeItem(at: root) }

        try await makeTinyValidM4A(at: root.appendingPathComponent("120000_audio_system.m4a"))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)

        let result = await classifyAudioSources(in: files, timePrefix: "120000", verbose: false)

        if case .ready(let inputs) = result {
            #expect(inputs.count == 1)
        } else {
            Issue.record("Expected ready")
        }
    }

    @Test func classifyUnreadable() async throws {
        let root = try makeTempDirectory("audio-source-readiness-unreadable")
        defer { try? FileManager.default.removeItem(at: root) }

        try corruptM4A(at: root.appendingPathComponent("120000_audio_system.m4a"))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)

        let result = await classifyAudioSources(in: files, timePrefix: "120000", verbose: false)

        guard case .unreadable = result else {
            Issue.record("Expected unreadable")
            return
        }
    }

    @Test func classifyPartialReadabilityIsReady() async throws {
        let root = try makeTempDirectory("audio-source-readiness-partial")
        defer { try? FileManager.default.removeItem(at: root) }

        try await makeTinyValidM4A(at: root.appendingPathComponent("120000_audio_system.m4a"))
        try corruptM4A(at: root.appendingPathComponent("120000_audio_mic.m4a"))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)

        let result = await classifyAudioSources(in: files, timePrefix: "120000", verbose: false)

        if case .ready(let inputs) = result {
            #expect(inputs.count == 1)
        } else {
            Issue.record("Expected ready with one readable input")
        }
    }
}
