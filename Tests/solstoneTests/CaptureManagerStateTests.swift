// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("CaptureManager.State")
struct CaptureManagerStateTests {
    // MARK: - isIdle

    @Test func idleStateIsIdle() {
        #expect(CaptureManager.State.idle.isIdle == true)
    }

    @Test func recordingStateIsNotIdle() {
        #expect(CaptureManager.State.recording.isIdle == false)
    }

    @Test func pausedStateIsNotIdle() {
        #expect(CaptureManager.State.paused(reasons: [.user]).isIdle == false)
    }

    @Test func errorStateIsNotIdle() {
        #expect(CaptureManager.State.error("fail").isIdle == false)
    }

    // MARK: - isRecording

    @Test func recordingStateIsRecording() {
        #expect(CaptureManager.State.recording.isRecording == true)
    }

    @Test func idleStateIsNotRecording() {
        #expect(CaptureManager.State.idle.isRecording == false)
    }

    // MARK: - isPaused

    @Test func pausedStateIsPaused() {
        #expect(CaptureManager.State.paused(reasons: [.user]).isPaused == true)
    }

    @Test func idleStateIsNotPaused() {
        #expect(CaptureManager.State.idle.isPaused == false)
    }

    // MARK: - isError

    @Test func errorStateIsError() {
        #expect(CaptureManager.State.error("something").isError == true)
    }

    @Test func idleStateIsNotError() {
        #expect(CaptureManager.State.idle.isError == false)
    }

    // MARK: - label

    @Test func idleLabel() {
        #expect(CaptureManager.State.idle.label == "idle")
    }

    @Test func recordingLabel() {
        #expect(CaptureManager.State.recording.label == "recording")
    }

    @Test func pausedLabel() {
        #expect(CaptureManager.State.paused(reasons: [.user]).label == "paused")
    }

    @Test func pausedReasonsExposeReasonSet() {
        #expect(CaptureManager.State.paused(reasons: [.sleep, .lock]).pausedReasons == [.sleep, .lock])
        #expect(CaptureManager.State.recording.pausedReasons.isEmpty)
    }

    @Test func errorLabel() {
        #expect(CaptureManager.State.error("something went wrong").label == "error")
    }
}
