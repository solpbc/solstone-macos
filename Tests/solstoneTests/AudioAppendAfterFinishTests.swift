// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import Testing
@testable import solstone

struct AudioAppendAfterFinishTests {
    /// The non-silent append runs under the writer lock, so once finish()
    /// (via extractTimingState) sets isFinished, any in-flight or subsequent
    /// appendAudio is suppressed instead of writing to a finalized input.
    /// This closes the producer-vs-teardown race that previously appended
    /// outside the lock (the 28effae crash class).
    ///
    /// Note: the append ObjC wrapper is defense-in-depth; input.append does not
    /// raise on this SDK (verified empirically - it returns true/false), so its
    /// containment is not unit-reproducible. The ObjCExceptionCatcher barrier
    /// mechanism itself is already covered by AudioFinalizeExceptionTests.
    @Test func appendAfterFinishIsSuppressedBySerialization() async throws {
        let root = try makeTempDirectory("audio-append-after-finish")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("system.m4a"),
            trackType: .systemAudio,
            segmentStartTime: .zero
        )

        // Non-silent buffer enters the guarded append path.
        writer.appendAudio(try makeNonSilentAudioSampleBuffer(seconds: 0.02))
        let attemptsBeforeFinish = writer._appendAttemptCountForTesting
        #expect(attemptsBeforeFinish > 0)

        let info = await writer.finish()
        #expect(info.hasAudio == true)
        #expect(info.trackType.sourceID == "system")

        // After finish() set isFinished under the lock, further appends are
        // suppressed - they must not reach input.append.
        writer.appendAudio(try makeNonSilentAudioSampleBuffer(seconds: 0.02))
        #expect(writer._appendAttemptCountForTesting == attemptsBeforeFinish)
    }
}
