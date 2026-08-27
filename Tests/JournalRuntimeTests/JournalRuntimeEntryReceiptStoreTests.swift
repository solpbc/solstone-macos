// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("JournalRuntimeEntryReceiptStore")
struct JournalRuntimeEntryReceiptStoreTests {
    @Test func persistsClosedChainWithApplicationSupportSiblingLockAndRejectsTemporaryRoot() throws {
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
        #expect(!FileManager.default.fileExists(atPath: baseURL
            .appendingPathComponent("Solstone/journal-runtime-entry-receipts.lock").path))

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

    @Test func lockContentionDoesNotCreateStoreAndFreshWritesRecover() throws {
        let baseURL = try makeReceiptBaseURL()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let sink = FileJournalRuntimeEntryReceiptSink(
            applicationSupportBaseURL: baseURL,
            clock: FixedReceiptClock(),
            lockTimeout: .zero
        )
        let attempt = JournalRuntimeEntryAttemptID()
        let lockURL = FileJournalRuntimeEntryReceiptSink.lockURL(applicationSupportBaseURL: baseURL)

        try withHeldReceiptLock(at: lockURL) {
            #expect(sink.appendSynchronously(outerDraft(attempt)) == .unavailable(.lockTimeout))
            #expect(sink.validate(attemptID: attempt) == .unavailable(.lockTimeout))
            #expect(!FileManager.default.fileExists(atPath: baseURL.appendingPathComponent("Solstone").path))
        }

        #expect(sink.appendSynchronously(outerDraft(attempt)) == .recorded)
        #expect(sink.appendSynchronously(payloadEntryDraft(attempt)) == .recorded)
        #expect(sink.appendSynchronously(payloadExitDraft(attempt)) == .recorded)
        #expect(sink.validate(attemptID: attempt).isValidClosed)
    }

    @Test func lockContentionDoesNotMutateExistingOrMalformedStore() throws {
        let baseURL = try makeReceiptBaseURL()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let sink = FileJournalRuntimeEntryReceiptSink(
            applicationSupportBaseURL: baseURL,
            clock: FixedReceiptClock(),
            lockTimeout: .zero
        )
        let validAttempt = JournalRuntimeEntryAttemptID()
        #expect(sink.appendSynchronously(outerDraft(validAttempt)) == .recorded)
        #expect(sink.appendSynchronously(payloadEntryDraft(validAttempt)) == .recorded)
        #expect(sink.appendSynchronously(payloadExitDraft(validAttempt)) == .recorded)

        let fileURL = FileJournalRuntimeEntryReceiptSink.fileURL(applicationSupportBaseURL: baseURL)
        let validBytes = try Data(contentsOf: fileURL)
        let lockURL = FileJournalRuntimeEntryReceiptSink.lockURL(applicationSupportBaseURL: baseURL)
        try withHeldReceiptLock(at: lockURL) {
            #expect(sink.appendSynchronously(outerDraft(JournalRuntimeEntryAttemptID())) == .unavailable(.lockTimeout))
            #expect(sink.validate(attemptID: validAttempt) == .unavailable(.lockTimeout))
        }
        #expect(try Data(contentsOf: fileURL) == validBytes)
        #expect(try receiptStagingURLs(in: fileURL.deletingLastPathComponent()).isEmpty)

        let malformedURL = baseURL.appendingPathComponent("malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedURL.appendingPathComponent("Solstone"), withIntermediateDirectories: true)
        let malformedSink = FileJournalRuntimeEntryReceiptSink(
            applicationSupportBaseURL: malformedURL,
            clock: FixedReceiptClock(),
            lockTimeout: .zero
        )
        let malformedFileURL = FileJournalRuntimeEntryReceiptSink.fileURL(applicationSupportBaseURL: malformedURL)
        let malformedBytes = Data("malformed receipts".utf8)
        try malformedBytes.write(to: malformedFileURL)
        try withHeldReceiptLock(at: FileJournalRuntimeEntryReceiptSink.lockURL(applicationSupportBaseURL: malformedURL)) {
            #expect(malformedSink.appendSynchronously(outerDraft(JournalRuntimeEntryAttemptID())) == .unavailable(.lockTimeout))
            #expect(malformedSink.validate(attemptID: JournalRuntimeEntryAttemptID()) == .unavailable(.lockTimeout))
        }
        #expect(try Data(contentsOf: malformedFileURL) == malformedBytes)
        #expect(try receiptStagingURLs(in: malformedFileURL.deletingLastPathComponent()).isEmpty)
    }

    @Test func missingApplicationSupportBaseFailsWithoutCreatingFiles() {
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".journal-runtime-entry-receipts-missing-\(UUID().uuidString)", isDirectory: true)
        let sink = FileJournalRuntimeEntryReceiptSink(
            applicationSupportBaseURL: baseURL,
            clock: FixedReceiptClock(),
            lockTimeout: .zero
        )

        #expect(sink.appendSynchronously(outerDraft(JournalRuntimeEntryAttemptID())) == .unavailable(.lockFailure))
        #expect(sink.validate(attemptID: JournalRuntimeEntryAttemptID()) == .unavailable(.lockFailure))
        #expect(!FileManager.default.fileExists(atPath: baseURL.path))
    }

    @Test func rejectsReceiptMissingRequiredAppKernelStartTimeKey() throws {
        let baseURL = try makeReceiptBaseURL()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let sink = FileJournalRuntimeEntryReceiptSink(applicationSupportBaseURL: baseURL)
        let attempt = JournalRuntimeEntryAttemptID()
        #expect(sink.appendSynchronously(outerDraft(attempt)) == .recorded)

        let fileURL = FileJournalRuntimeEntryReceiptSink.fileURL(applicationSupportBaseURL: baseURL)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var attempts = try #require(envelope["attempts"] as? [[String: Any]])
        var firstAttempt = try #require(attempts.first)
        var records = try #require(firstAttempt["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "app_kernel_start_time_us")
        firstAttempt["records"] = records
        attempts[0] = firstAttempt
        envelope["attempts"] = attempts
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: fileURL)

        #expect(sink.validate(attemptID: attempt) == .unavailable(.canonicalInvalid))
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

    @Test func rejectsOuterEntryWithMissingAppKernelStartTime() {
        let attempt = JournalRuntimeEntryAttemptID()
        let records = [
            outerRecord(
                attempt,
                sequence: 0,
                appIdentity: identity(appKernelStartTimeMicroseconds: 0)
            )
        ]

        #expect(JournalRuntimeEntryReceiptChainValidator(records: records)
            .validate(attemptID: attempt) == .invalid(.malformed))
    }

    @Test func keepsAppKernelStartIdentityDistinctAcrossClosedAttempts() {
        let sink = InMemoryJournalRuntimeEntryReceiptSink()
        let first = JournalRuntimeEntryAttemptID()
        let second = JournalRuntimeEntryAttemptID()
        let firstIdentity = identity(appKernelStartTimeMicroseconds: 1_000_000)
        let secondIdentity = identity(appKernelStartTimeMicroseconds: 1_000_001)

        for (attempt, appIdentity) in [(first, firstIdentity), (second, secondIdentity)] {
            #expect(sink.appendSynchronously(outerDraft(attempt, identity: appIdentity)) == .recorded)
            #expect(sink.appendSynchronously(payloadEntryDraft(attempt, appIdentity: appIdentity)) == .recorded)
            #expect(sink.appendSynchronously(payloadExitDraft(attempt, appIdentity: appIdentity)) == .recorded)
            #expect(sink.validate(attemptID: attempt).isValidClosed)
            #expect(sink.storedRecords(attemptID: attempt).allSatisfy {
                appKernelStartTimeMicroseconds(of: $0) == appIdentity.appKernelStartTimeMicroseconds
            })
        }
    }

    @Test func rejectsPayloadWithDifferentAppKernelStartTime() {
        let attempt = JournalRuntimeEntryAttemptID()
        let outerIdentity = identity(appKernelStartTimeMicroseconds: 1_000_000)
        let forgedIdentity = identity(appKernelStartTimeMicroseconds: 1_000_001)
        let records = [
            outerRecord(attempt, sequence: 0, appIdentity: outerIdentity),
            payloadEntryRecord(attempt, sequence: 1, startTime: 1_000, appIdentity: forgedIdentity)
        ]

        #expect(JournalRuntimeEntryReceiptChainValidator(records: records)
            .validate(attemptID: attempt) == .invalid(.inconsistentAppIdentity))
    }
}

private extension JournalRuntimeEntryReceiptChainValidationResult {
    var isValidClosed: Bool {
        if case .validClosed = self { return true }
        return false
    }
}

private func identity(
    bundleIdentifier: String = "app.solstone.journal",
    appKernelStartTimeMicroseconds: Int64 = 1_000_000
) -> JournalRuntimeEntryReceiptAppIdentity {
    JournalRuntimeEntryReceiptAppIdentity(
        appPID: 99,
        bundleIdentifier: bundleIdentifier,
        bundleShortVersion: "2.0.0",
        bundleVersion: "25",
        locationClass: .standard,
        appKernelStartTimeMicroseconds: appKernelStartTimeMicroseconds
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
    generation: UInt64 = 1,
    appIdentity: JournalRuntimeEntryReceiptAppIdentity = identity()
) -> JournalRuntimeEntryReceiptDraft {
    .payloadEntry(.init(
        attemptID: attempt,
        observedAtUnixMilliseconds: 2,
        appIdentity: appIdentity,
        generation: generation,
        childPID: 4242,
        childKernelStartTimeMicroseconds: 1_000,
        provenance: provenance()
    ))
}

private func payloadExitDraft(
    _ attempt: JournalRuntimeEntryAttemptID,
    appIdentity: JournalRuntimeEntryReceiptAppIdentity = identity()
) -> JournalRuntimeEntryReceiptDraft {
    .payloadExit(.init(
        attemptID: attempt,
        observedAtUnixMilliseconds: 3,
        appIdentity: appIdentity,
        generation: 1,
        childPID: 4242,
        childKernelStartTimeMicroseconds: 1_000,
        expectedStop: false,
        terminationStatus: 0
    ))
}

private func outerRecord(
    _ attempt: JournalRuntimeEntryAttemptID,
    sequence: UInt64,
    appIdentity: JournalRuntimeEntryReceiptAppIdentity = identity()
) -> JournalRuntimeEntryReceipt {
    .outerEntry(.init(sequence: sequence, draft: .init(
        attemptID: attempt, observedAtUnixMilliseconds: 1, appIdentity: appIdentity
    )))
}

private func payloadEntryRecord(
    _ attempt: JournalRuntimeEntryAttemptID,
    sequence: UInt64,
    startTime: Int64,
    appIdentity: JournalRuntimeEntryReceiptAppIdentity = identity()
) -> JournalRuntimeEntryReceipt {
    .payloadEntry(.init(sequence: sequence, draft: .init(
        attemptID: attempt,
        observedAtUnixMilliseconds: 2,
        appIdentity: appIdentity,
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

private func appKernelStartTimeMicroseconds(of record: JournalRuntimeEntryReceipt) -> Int64 {
    switch record {
    case .outerEntry(let entry): entry.draft.appIdentity.appKernelStartTimeMicroseconds
    case .payloadEntry(let entry): entry.draft.appIdentity.appKernelStartTimeMicroseconds
    case .payloadExit(let entry): entry.draft.appIdentity.appKernelStartTimeMicroseconds
    }
}

private final class FixedReceiptClock: MonotonicClock, @unchecked Sendable {
    func now() -> Duration { .zero }
    func sleep(for duration: Duration) async {}
}

private func makeReceiptBaseURL() throws -> URL {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".journal-runtime-entry-receipts-lock-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func withHeldReceiptLock<Result>(at url: URL, body: () throws -> Result) throws -> Result {
    let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
}

private func receiptStagingURLs(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(".journal-runtime-entry-receipts.") }
}
