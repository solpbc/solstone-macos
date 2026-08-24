// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing
@testable import solstone

@MainActor
@Suite("Diagnostic evidence recorder")
struct DiagnosticEvidenceRecorderTests {
    @Test func multiEnqueueAutonomyAndProducerTimestamps() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let bytes = GatedDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let taskStarts = LockedCounter()
        let recorder = DiagnosticEvidenceRecorder(
            store: store,
            now: { clock.now },
            taskStarted: { taskStarts.increment() }
        )

        recorder.enqueue(.appLaunch)
        #expect(await Task.detached { bytes.waitForFirstRead() }.value)
        #expect(taskStarts.count == 1)
        #expect(bytes.counts().reads == 1)

        let firstTime = clock.now
        let secondTime = firstTime.addingTimeInterval(1)
        let thirdTime = secondTime.addingTimeInterval(1)
        let fourthTime = thirdTime.addingTimeInterval(1)
        clock.now = secondTime
        recorder.enqueue(.screenRecordingGranted)
        clock.now = thirdTime
        recorder.enqueue(.microphoneGranted)
        clock.now = fourthTime
        recorder.enqueue(.captureOn)
        // This waits only for MainActor task scheduling; 2s was contention-bound behind full-suite snapshot work, not tail ordering.
        try await withTimeout(seconds: 10) {
            await taskStarts.waitUntilCount(4)
        }
        #expect(bytes.counts().reads == 1)

        bytes.releaseFirstRead()
        await recorder.drain()

        guard case .available(let envelope) = await store.read() else {
            Issue.record("expected persisted evidence")
            return
        }
        #expect(envelope.entries == [
            DiagnosticEvidenceEntry(code: .appLaunch, firstAt: firstTime, lastAt: firstTime, repeatCount: 1),
            DiagnosticEvidenceEntry(code: .screenRecordingGranted, firstAt: secondTime, lastAt: secondTime, repeatCount: 1),
            DiagnosticEvidenceEntry(code: .microphoneGranted, firstAt: thirdTime, lastAt: thirdTime, repeatCount: 1),
            DiagnosticEvidenceEntry(code: .captureOn, firstAt: fourthTime, lastAt: fourthTime, repeatCount: 1),
        ])

        let beforeSecondDrain = bytes.counts()
        await recorder.drain()
        #expect(bytes.counts() == beforeSecondDrain)
        #expect(taskStarts.count == 4)
    }

    @Test func dormantRecorderDoesNothing() async {
        let recorder = DiagnosticEvidenceRecorder.dormant
        recorder.enqueue(.appLaunch)
        await recorder.drain()
    }
}
