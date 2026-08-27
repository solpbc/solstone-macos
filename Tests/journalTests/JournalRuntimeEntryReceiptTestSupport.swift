// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntime
@testable import journal

final class RecordingJournalRuntimeEntryReceiptSink: JournalRuntimeEntryReceiptSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [JournalRuntimeEntryReceiptDraft] = []
    var failure: JournalRuntimeEntryReceiptWriteFailure?

    func appendSynchronously(_ draft: JournalRuntimeEntryReceiptDraft) -> JournalRuntimeEntryReceiptWriteResult {
        lock.withLock {
            if let failure { return .unavailable(failure) }
            values.append(draft)
            return .recorded
        }
    }

    func append(_ draft: JournalRuntimeEntryReceiptDraft) async -> JournalRuntimeEntryReceiptWriteResult {
        appendSynchronously(draft)
    }

    func drafts() -> [JournalRuntimeEntryReceiptDraft] {
        lock.withLock { values }
    }
}

@MainActor
func makeJournalTestReceiptContext(
    sink: RecordingJournalRuntimeEntryReceiptSink = RecordingJournalRuntimeEntryReceiptSink()
) -> JournalRuntimeEntryReceiptContext {
    let attemptID = JournalRuntimeEntryAttemptID()
    let identity = JournalRuntimeEntryReceiptAppIdentity(
        appPID: 99,
        bundleIdentifier: "app.solstone.journal",
        bundleShortVersion: "2.0.0",
        bundleVersion: "25",
        locationClass: .standard
    )
    _ = sink.appendSynchronously(.outerEntry(.init(
        attemptID: attemptID,
        observedAtUnixMilliseconds: 1,
        appIdentity: identity
    )))
    return JournalRuntimeEntryReceiptContext(
        attemptID: attemptID,
        sink: sink,
        appIdentity: identity,
        candidateProvenance: JournalRuntimeEntryCandidateProvenance(
            source: "J",
            target: .init(bundleIdentifier: "app.solstone.journal", bundleShortVersion: "2.0.0", bundleVersion: "25"),
            runtimeArchiveSHA256: String(repeating: "a", count: 64),
            manifestSHA256: String(repeating: "b", count: 64),
            releaseReceiptSHA256: String(repeating: "c", count: 64),
            signingReceiptSHA256: String(repeating: "d", count: 64),
            runtimeTreeSHA256: String(repeating: "e", count: 64)
        )
    )
}

@MainActor
func configureInMemoryReceiptContext(
    _ supervisor: JournalSupervisor,
    sink: RecordingJournalRuntimeEntryReceiptSink = RecordingJournalRuntimeEntryReceiptSink()
) -> JournalRuntimeEntryReceiptContext {
    let context = makeJournalTestReceiptContext(sink: sink)
    supervisor.configureReceiptContext(context)
    return context
}
