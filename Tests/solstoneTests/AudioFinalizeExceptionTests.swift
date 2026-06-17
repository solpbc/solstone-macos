// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import Testing
@testable import solstone

struct AudioFinalizeExceptionTests {
    /// Exercises the guard-PASS path plus ObjC barrier: removing the
    /// ObjCExceptionCatcher.`try` wrapper makes finish() raise an uncaught
    /// NSException -> SIGABRT. This is the genuine production throw.
    @Test func finishContainsObjCFinalizeExceptionWhileWriterStillReportsWriting() async throws {
        let root = try makeTempDirectory("audio-finalize-exception")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("system.m4a"),
            trackType: .systemAudio,
            segmentStartTime: .zero
        )

        writer.appendAudio(try makeSilentAudioSampleBuffer(seconds: 0.02))
        writer._forceLastBufferTimeForTesting(.invalid)

        let info = await writer.finish()

        #expect(info.hasAudio == true)
        #expect(info.trackType.sourceID == "system")
    }
}
