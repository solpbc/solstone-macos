// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalRuntime

@Suite("JournalRuntimeEntryReceiptStore")
struct JournalRuntimeEntryReceiptStoreTests {
    @Test func persistsClosedChainWithSiblingLockAndRejectsTemporaryRoot() throws {
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".journal-runtime-entry-receipts-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let sink = FileJournalRuntimeEntryReceiptSink(applicationSupportBaseURL: baseURL)
        let attempt = JournalRuntimeEntryAttemptID()

        #expect(sink.appendSynchronously(outerDraft(attempt)) == .recorded)
        #expect(sink.appendSynchronously(payloadEntryDraft(attempt)) == .recorded)
        #expect(sink.appendSynchronously(payloadExitDraft(attempt)) == .recorded)
        #expect(sink.validate(attemptID: attempt).isValidClosed)
        #expect(FileManager.default.fileExists(atPath: FileJournalRuntimeEntryReceiptSink.fileURL(
            applicationSupportBaseURL: baseURL
        ).path))
        #expect(FileManager.default.fileExists(atPath: FileJournalRuntimeEntryReceiptSink.lockURL(
            applicationSupportBaseURL: baseURL
        ).path))

        let temporarySink = FileJournalRuntimeEntryReceiptSink(
            applicationSupportBaseURL: FileManager.default.temporaryDirectory
        )
        #expect(temporarySink.appendSynchronously(outerDraft(JournalRuntimeEntryAttemptID())) == .unavailable(.storageRootRejected))
    }

    @Test func rejectsSubdirectoryBeneathTemporaryRoot() {
        let nestedTemporaryBaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-runtime-entry-receipts-\(UUID().uuidString)", isDirectory: true)
        let sink = FileJournalRuntimeEntryReceiptSink(applicationSupportBaseURL: nestedTemporaryBaseURL)

        #expect(sink.appendSynchronously(outerDraft(JournalRuntimeEntryAttemptID())) == .unavailable(.storageRootRejected))
    }

    @Test func evictsOnlyOldClosedAttemptsAndPreservesExistingChainWhenCurrentWriteFails() {
        let sink = InMemoryJournalRuntimeEntryReceiptSink()
        let first = JournalRuntimeEntryAttemptID()
        #expect(sink.appendSynchronously(outerDraft(first)) == .recorded)
        for _ in 0..<16 {
            #expect(sink.appendSynchronously(outerDraft(JournalRuntimeEntryAttemptID())) == .recorded)
        }
        #expect(sink.validate(attemptID: first) == .invalid(.missingAttempt))

        let preserved = JournalRuntimeEntryAttemptID()
        #expect(sink.appendSynchronously(outerDraft(preserved)) == .recorded)
        sink.appendFailure = .lockTimeout
        let unavailable = JournalRuntimeEntryAttemptID()
        #expect(sink.appendSynchronously(outerDraft(unavailable)) == .unavailable(.lockTimeout))
        #expect(sink.validate(attemptID: preserved).isValidClosed)
        #expect(sink.validate(attemptID: unavailable) == .invalid(.missingAttempt))
    }

    @Test func rejectsOversizedRecordWithoutMutatingExistingEnvelope() {
        let sink = InMemoryJournalRuntimeEntryReceiptSink()
        let preserved = JournalRuntimeEntryAttemptID()
        #expect(sink.appendSynchronously(outerDraft(preserved)) == .recorded)
        let before = sink.storedRecords(attemptID: preserved)

        // Bundle identity fields are the only variable-length whitelisted values. This remains
        // structurally valid while exceeding the 2 KiB encoded-record bound.
        let oversized = JournalRuntimeEntryAttemptID()
        #expect(sink.appendSynchronously(outerDraft(
            oversized,
            identity: identity(bundleIdentifier: String(repeating: "a", count: 2_500))
        )) == .unavailable(.recordRejected))

        #expect(sink.storedRecords(attemptID: preserved) == before)
        #expect(sink.validate(attemptID: oversized) == .invalid(.missingAttempt))
    }

    @Test func rejectsFileBoundWithoutEvictingOpenAttempts() {
        let sink = InMemoryJournalRuntimeEntryReceiptSink()
        let openAttempts = (0..<15).map { _ in JournalRuntimeEntryAttemptID() }
        for attempt in openAttempts {
            #expect(sink.appendSynchronously(outerDraft(attempt)) == .recorded)
            #expect(sink.appendSynchronously(payloadEntryDraft(attempt, generation: 1)) == .recorded)
        }

        var hitFileBound = false
        for index in 0..<512 {
            let attempt = openAttempts[index % openAttempts.count]
            let generation = UInt64(index / openAttempts.count + 2)
            let result = sink.appendSynchronously(payloadEntryDraft(attempt, generation: generation))
            if result == .unavailable(.boundsExceeded) {
                hitFileBound = true
                break
            }
            #expect(result == .recorded)
        }
        guard hitFileBound else {
            Issue.record("expected open attempts to reach the 128 KiB receipt-file bound")
            return
        }

        let before = openAttempts.map { sink.storedRecords(attemptID: $0) }
        let currentAttempt = JournalRuntimeEntryAttemptID()
        let largeCurrentOuter = outerDraft(
            currentAttempt,
            identity: identity(bundleIdentifier: String(repeating: "a", count: 1_700))
        )
        let probe = InMemoryJournalRuntimeEntryReceiptSink()
        #expect(probe.appendSynchronously(largeCurrentOuter) == .recorded)

        #expect(sink.appendSynchronously(largeCurrentOuter) == .unavailable(.boundsExceeded))
        for (attempt, records) in zip(openAttempts, before) {
            #expect(sink.storedRecords(attemptID: attempt) == records)
        }
        #expect(sink.validate(attemptID: currentAttempt) == .invalid(.missingAttempt))
    }
}

@Suite("JournalRuntimeEntryReceiptChainValidator")
struct JournalRuntimeEntryReceiptChainValidatorTests {
    @Test func rejectsDuplicateReorderedMissingAndCrossAttemptRecords() {
        let attempt = JournalRuntimeEntryAttemptID()
        let other = JournalRuntimeEntryAttemptID()
        let outer = outerRecord(attempt, sequence: 0)
        let entry = payloadEntryRecord(attempt, sequence: 1, startTime: 1_000)
        let duplicate = payloadEntryRecord(attempt, sequence: 2, startTime: 1_000)
        let missingPeer = payloadExitRecord(attempt, sequence: 1, startTime: 1_000)
        let crossAttempt = payloadEntryRecord(other, sequence: 1, startTime: 1_000)

        #expect(JournalRuntimeEntryReceiptChainValidator(records: [outer, entry, duplicate])
            .validate(attemptID: attempt) == .invalid(.duplicatePayloadEntry))
        #expect(JournalRuntimeEntryReceiptChainValidator(records: [outer, missingPeer])
            .validate(attemptID: attempt) == .invalid(.missingPeer))
        #expect(JournalRuntimeEntryReceiptChainValidator(records: [outer, crossAttempt])
            .validate(attemptID: attempt) == .invalid(.crossAttemptRecord))
        #expect(JournalRuntimeEntryReceiptChainValidator(records: [outer, payloadEntryRecord(attempt, sequence: 3, startTime: 1_000)])
            .validate(attemptID: attempt) == .invalid(.reorderedRecord))
    }

    @Test func rejectsExitForSamePIDWithDifferentKernelStartTime() {
        let attempt = JournalRuntimeEntryAttemptID()
        let records = [
            outerRecord(attempt, sequence: 0),
            payloadEntryRecord(attempt, sequence: 1, startTime: 1_000),
            payloadExitRecord(attempt, sequence: 2, startTime: 2_000)
        ]

        #expect(JournalRuntimeEntryReceiptChainValidator(records: records)
            .validate(attemptID: attempt) == .invalid(.samePIDDifferentStartTime))
    }
}

private extension JournalRuntimeEntryReceiptChainValidationResult {
    var isValidClosed: Bool {
        if case .validClosed = self { return true }
        return false
    }
}

private func identity(bundleIdentifier: String = "app.solstone.journal") -> JournalRuntimeEntryReceiptAppIdentity {
    JournalRuntimeEntryReceiptAppIdentity(
        appPID: 99,
        bundleIdentifier: bundleIdentifier,
        bundleShortVersion: "2.0.0",
        bundleVersion: "25",
        locationClass: .standard
    )
}

private func provenance() -> JournalRuntimeEntryCandidateProvenance {
    JournalRuntimeEntryCandidateProvenance(
        source: "J",
        target: .init(bundleIdentifier: "app.solstone.journal", bundleShortVersion: "2.0.0", bundleVersion: "25"),
        runtimeArchiveSHA256: String(repeating: "a", count: 64),
        manifestSHA256: String(repeating: "b", count: 64),
        releaseReceiptSHA256: String(repeating: "c", count: 64),
        signingReceiptSHA256: String(repeating: "d", count: 64),
        runtimeTreeSHA256: String(repeating: "e", count: 64)
    )
}

private func outerDraft(
    _ attempt: JournalRuntimeEntryAttemptID,
    identity: JournalRuntimeEntryReceiptAppIdentity = identity()
) -> JournalRuntimeEntryReceiptDraft {
    .outerEntry(.init(attemptID: attempt, observedAtUnixMilliseconds: 1, appIdentity: identity))
}

private func payloadEntryDraft(
    _ attempt: JournalRuntimeEntryAttemptID,
    generation: UInt64 = 1
) -> JournalRuntimeEntryReceiptDraft {
    .payloadEntry(.init(
        attemptID: attempt,
        observedAtUnixMilliseconds: 2,
        appIdentity: identity(),
        generation: generation,
        childPID: 4242,
        childKernelStartTimeMicroseconds: 1_000,
        provenance: provenance()
    ))
}

private func payloadExitDraft(_ attempt: JournalRuntimeEntryAttemptID) -> JournalRuntimeEntryReceiptDraft {
    .payloadExit(.init(
        attemptID: attempt,
        observedAtUnixMilliseconds: 3,
        appIdentity: identity(),
        generation: 1,
        childPID: 4242,
        childKernelStartTimeMicroseconds: 1_000,
        expectedStop: false,
        terminationStatus: 0
    ))
}

private func outerRecord(_ attempt: JournalRuntimeEntryAttemptID, sequence: UInt64) -> JournalRuntimeEntryReceipt {
    .outerEntry(.init(sequence: sequence, draft: .init(
        attemptID: attempt, observedAtUnixMilliseconds: 1, appIdentity: identity()
    )))
}

private func payloadEntryRecord(
    _ attempt: JournalRuntimeEntryAttemptID,
    sequence: UInt64,
    startTime: Int64
) -> JournalRuntimeEntryReceipt {
    .payloadEntry(.init(sequence: sequence, draft: .init(
        attemptID: attempt,
        observedAtUnixMilliseconds: 2,
        appIdentity: identity(),
        generation: 1,
        childPID: 4242,
        childKernelStartTimeMicroseconds: startTime,
        provenance: provenance()
    )))
}

private func payloadExitRecord(
    _ attempt: JournalRuntimeEntryAttemptID,
    sequence: UInt64,
    startTime: Int64
) -> JournalRuntimeEntryReceipt {
    .payloadExit(.init(sequence: sequence, draft: .init(
        attemptID: attempt,
        observedAtUnixMilliseconds: 3,
        appIdentity: identity(),
        generation: 1,
        childPID: 4242,
        childKernelStartTimeMicroseconds: startTime,
        expectedStop: false,
        terminationStatus: 0
    )))
}
