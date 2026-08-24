// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Dispatch
import Foundation
import Testing
@testable import solstone

private final class GatedDiagnosticEvidenceBytesStore: DiagnosticEvidenceBytesStoring, @unchecked Sendable {
    private let base = InMemoryDiagnosticEvidenceBytesStore()
    private let lock = NSLock()
    private let firstRead = DispatchSemaphore(value: 0)
    private let releaseRead = DispatchSemaphore(value: 0)
    private var shouldGateFirstRead = true
    private(set) var readCanonicalCount = 0
    private(set) var commitCount = 0

    func readCanonical() -> DiagnosticEvidenceBytesRead {
        let shouldBlock = lock.withLock {
            readCanonicalCount += 1
            defer { shouldGateFirstRead = false }
            return shouldGateFirstRead
        }
        if shouldBlock {
            firstRead.signal()
            releaseRead.wait()
        }
        return base.readCanonical()
    }

    func encode(_ envelope: DiagnosticEvidenceEnvelope) -> DiagnosticEvidenceEncodingResult {
        base.encode(envelope)
    }

    func stage(_ data: Data) -> DiagnosticEvidenceStagingResult {
        base.stage(data)
    }

    func readStaged(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceBytesRead {
        base.readStaged(staging)
    }

    func commit(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceCommitResult {
        let result = base.commit(staging)
        if result == .committed {
            lock.withLock { commitCount += 1 }
        }
        return result
    }

    func removeStaging(_ staging: DiagnosticEvidenceStagingHandle) {
        base.removeStaging(staging)
    }

    func waitForFirstRead() -> Bool {
        firstRead.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstRead() {
        releaseRead.signal()
    }

    func counts() -> (reads: Int, commits: Int) {
        lock.withLock { (readCanonicalCount, commitCount) }
    }
}

@MainActor
@Suite("Diagnostic evidence recorder")
struct DiagnosticEvidenceRecorderTests {
    @Test func enqueueStartsAutonomousOrderedWorkAndDrainIsReadOnly() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let bytes = GatedDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        var taskStartCount = 0
        let recorder = DiagnosticEvidenceRecorder(
            store: store,
            now: { clock.now },
            taskStarted: { taskStartCount += 1 }
        )

        recorder.enqueue(.appLaunch)
        #expect(await Task.detached { bytes.waitForFirstRead() }.value)
        #expect(taskStartCount == 1)
        #expect(bytes.counts().reads == 1)

        let producerTime = clock.now
        clock.now = producerTime.addingTimeInterval(60)
        bytes.releaseFirstRead()
        await recorder.drain()

        guard case .available(let envelope) = await store.read() else {
            Issue.record("expected persisted evidence")
            return
        }
        #expect(envelope.entries == [
            DiagnosticEvidenceEntry(code: .appLaunch, firstAt: producerTime, lastAt: producerTime, repeatCount: 1),
        ])

        let beforeSecondDrain = bytes.counts()
        await recorder.drain()
        #expect(bytes.counts() == beforeSecondDrain)
    }

    @Test func dormantRecorderDoesNothing() async {
        let recorder = DiagnosticEvidenceRecorder.dormant
        recorder.enqueue(.appLaunch)
        await recorder.drain()
    }
}
