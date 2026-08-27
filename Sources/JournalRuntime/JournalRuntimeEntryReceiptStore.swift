// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

private let receiptSchemaVersion = 1
private let maximumReceiptRecordBytes = 2 * 1024
private let maximumReceiptFileBytes = 128 * 1024
private let maximumReceiptAttempts = 16

// The sink holds only immutable configuration. Each operation owns its file descriptor and local state.
public final class FileJournalRuntimeEntryReceiptSink: JournalRuntimeEntryReceiptSinking, JournalRuntimeEntryReceiptChainValidating, @unchecked Sendable {
    let applicationSupportBaseURL: URL
    private let clock: any MonotonicClock
    private let lockTimeout: Duration

    public convenience init(applicationSupportBaseURL: URL? = nil) {
        self.init(
            applicationSupportBaseURL: applicationSupportBaseURL ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0],
            clock: SystemMonotonicClock(),
            lockTimeout: .milliseconds(250)
        )
    }

    init(
        applicationSupportBaseURL: URL,
        clock: any MonotonicClock,
        lockTimeout: Duration = .milliseconds(250)
    ) {
        self.applicationSupportBaseURL = applicationSupportBaseURL.standardizedFileURL
        self.clock = clock
        self.lockTimeout = lockTimeout
    }

    static func fileURL(applicationSupportBaseURL: URL) -> URL {
        applicationSupportBaseURL
            .appendingPathComponent("Solstone", isDirectory: true)
            .appendingPathComponent("journal-runtime-entry-receipts.json")
    }

    static func lockURL(applicationSupportBaseURL: URL) -> URL {
        applicationSupportBaseURL
            .appendingPathComponent("journal-runtime-entry-receipts.lock")
    }

    public func appendSynchronously(_ draft: JournalRuntimeEntryReceiptDraft) -> JournalRuntimeEntryReceiptWriteResult {
        guard storageBaseIsAllowed(applicationSupportBaseURL) else {
            return unavailable(.storageRootRejected)
        }
        let fileURL = Self.fileURL(applicationSupportBaseURL: applicationSupportBaseURL)
        let lockURL = Self.lockURL(applicationSupportBaseURL: applicationSupportBaseURL)
        let lock = JournalRuntimeEntryReceiptFileLock(url: lockURL, clock: clock, timeout: lockTimeout)
        let (result, value) = lock.withExclusiveLock {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return unavailable(.lockFailure)
            }
            return appendLocked(draft, fileURL: fileURL)
        }
        switch result {
        case .acquired:
            return value ?? unavailable(.lockFailure)
        case .timedOut:
            return unavailable(.lockTimeout)
        case .failed:
            return unavailable(.lockFailure)
        }
    }

    public func append(_ draft: JournalRuntimeEntryReceiptDraft) async -> JournalRuntimeEntryReceiptWriteResult {
        appendSynchronously(draft)
    }

    public func validate(attemptID: JournalRuntimeEntryAttemptID) -> JournalRuntimeEntryReceiptChainValidationResult {
        guard storageBaseIsAllowed(applicationSupportBaseURL) else {
            return .unavailable(.storageRootRejected)
        }
        let fileURL = Self.fileURL(applicationSupportBaseURL: applicationSupportBaseURL)
        let lockURL = Self.lockURL(applicationSupportBaseURL: applicationSupportBaseURL)
        let lock = JournalRuntimeEntryReceiptFileLock(url: lockURL, clock: clock, timeout: lockTimeout)
        let (result, value) = lock.withExclusiveLock {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return Result<JournalRuntimeEntryReceiptChainValidationResult, JournalRuntimeEntryReceiptWriteFailure>.failure(.lockFailure)
            }
            return readEnvelope(fileURL: fileURL).map { JournalRuntimeEntryReceiptChainValidator.validate($0, attemptID: attemptID) }
        }
        switch result {
        case .acquired:
            guard let value else { return .unavailable(.canonicalReadFailed) }
            switch value {
            case .success(let validation): return validation
            case .failure(let failure): return .unavailable(failure)
            }
        case .timedOut:
            return .unavailable(.lockTimeout)
        case .failed:
            return .unavailable(.lockFailure)
        }
    }

    private func appendLocked(_ draft: JournalRuntimeEntryReceiptDraft, fileURL: URL) -> JournalRuntimeEntryReceiptWriteResult {
        let existing: ReceiptEnvelope
        switch readEnvelope(fileURL: fileURL) {
        case .success(let envelope):
            existing = envelope
        case .failure(let failure):
            return unavailable(failure)
        }

        var envelope = existing
        guard appendDraft(draft, to: &envelope) else {
            return unavailable(.recordRejected)
        }
        guard evictIfNeeded(envelope: &envelope, currentAttemptID: draft.attemptID) else {
            return unavailable(.boundsExceeded)
        }
        guard let encoded = encodeEnvelope(envelope), encoded.count <= maximumReceiptFileBytes else {
            return unavailable(.boundsExceeded)
        }
        return commit(encoded, to: fileURL)
    }

    private func unavailable(_ failure: JournalRuntimeEntryReceiptWriteFailure) -> JournalRuntimeEntryReceiptWriteResult {
        Logger.journalRuntimeEntryReceipts.warning("receipt write unavailable reason=\(failure.rawValue, privacy: .public)")
        return .unavailable(failure)
    }

    private func commit(_ data: Data, to fileURL: URL) -> JournalRuntimeEntryReceiptWriteResult {
        let stagingURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".journal-runtime-entry-receipts.\(UUID().uuidString).tmp")
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }
        do {
            try data.write(to: stagingURL)
        } catch {
            return unavailable(.stagingFailed)
        }
        guard let staged = try? Data(contentsOf: stagingURL), staged == data,
              case .success = decodeEnvelope(staged) else {
            return unavailable(.stagedValidationFailed)
        }
        // Same-directory POSIX rename is the sole commit point. Foundation's atomic-write and replacement APIs
        // are rejected here because they could replace canonical bytes before the actor validates staged bytes.
        guard Darwin.rename(stagingURL.path, fileURL.path) == 0 else {
            return unavailable(.renameFailed)
        }
        committed = true
        return .recorded
    }
}

// NSLock protects the test double's mutable envelope and injected failure state.
internal final class InMemoryJournalRuntimeEntryReceiptSink: JournalRuntimeEntryReceiptSinking, JournalRuntimeEntryReceiptChainValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var envelope = ReceiptEnvelope.empty
    var appendFailure: JournalRuntimeEntryReceiptWriteFailure?

    func appendSynchronously(_ draft: JournalRuntimeEntryReceiptDraft) -> JournalRuntimeEntryReceiptWriteResult {
        lock.withLock {
            if let appendFailure { return .unavailable(appendFailure) }
            var proposed = envelope
            guard appendDraft(draft, to: &proposed) else { return .unavailable(.recordRejected) }
            guard evictIfNeeded(envelope: &proposed, currentAttemptID: draft.attemptID),
                  let encoded = encodeEnvelope(proposed), encoded.count <= maximumReceiptFileBytes else {
                return .unavailable(.boundsExceeded)
            }
            envelope = proposed
            return .recorded
        }
    }

    func append(_ draft: JournalRuntimeEntryReceiptDraft) async -> JournalRuntimeEntryReceiptWriteResult {
        appendSynchronously(draft)
    }

    func validate(attemptID: JournalRuntimeEntryAttemptID) -> JournalRuntimeEntryReceiptChainValidationResult {
        lock.withLock { JournalRuntimeEntryReceiptChainValidator.validate(envelope, attemptID: attemptID) }
    }

    func storedRecords(attemptID: JournalRuntimeEntryAttemptID) -> [JournalRuntimeEntryReceipt] {
        lock.withLock {
            envelope.attempts.first(where: { $0.attemptID == attemptID })?.records ?? []
        }
    }
}

struct ReceiptEnvelope: Equatable {
    var attempts: [ReceiptAttempt]

    static var empty: ReceiptEnvelope { ReceiptEnvelope(attempts: []) }
}

struct ReceiptAttempt: Equatable {
    let attemptID: JournalRuntimeEntryAttemptID
    var records: [JournalRuntimeEntryReceipt]
}

private func appendDraft(_ draft: JournalRuntimeEntryReceiptDraft, to envelope: inout ReceiptEnvelope) -> Bool {
    if case .outerEntry = draft {
        guard !envelope.attempts.contains(where: { $0.attemptID == draft.attemptID }) else { return false }
        let record = makeRecord(draft, sequence: 0)
        guard encodedRecordSize(record) <= maximumReceiptRecordBytes else { return false }
        envelope.attempts.append(ReceiptAttempt(attemptID: draft.attemptID, records: [record]))
        return true
    }

    guard let index = envelope.attempts.firstIndex(where: { $0.attemptID == draft.attemptID }) else { return false }
    let record = makeRecord(draft, sequence: UInt64(envelope.attempts[index].records.count))
    guard encodedRecordSize(record) <= maximumReceiptRecordBytes else { return false }
    envelope.attempts[index].records.append(record)
    guard case .invalid = JournalRuntimeEntryReceiptChainValidator.validateAttempt(envelope.attempts[index]) else { return true }
    envelope.attempts[index].records.removeLast()
    return false
}

private func evictIfNeeded(envelope: inout ReceiptEnvelope, currentAttemptID: JournalRuntimeEntryAttemptID) -> Bool {
    while envelope.attempts.count > maximumReceiptAttempts || (encodeEnvelope(envelope)?.count ?? .max) > maximumReceiptFileBytes {
        guard let index = envelope.attempts.firstIndex(where: {
            $0.attemptID != currentAttemptID && JournalRuntimeEntryReceiptChainValidator.isClosed($0)
        }) else {
            return false
        }
        envelope.attempts.remove(at: index)
    }
    return true
}

private func makeRecord(_ draft: JournalRuntimeEntryReceiptDraft, sequence: UInt64) -> JournalRuntimeEntryReceipt {
    switch draft {
    case .outerEntry(let draft):
        .outerEntry(JournalRuntimeEntryReceiptOuterEntry(sequence: sequence, draft: draft))
    case .payloadEntry(let draft):
        .payloadEntry(JournalRuntimeEntryReceiptPayloadEntry(sequence: sequence, draft: draft))
    case .payloadExit(let draft):
        .payloadExit(JournalRuntimeEntryReceiptPayloadExit(sequence: sequence, draft: draft))
    }
}

private func readEnvelope(fileURL: URL) -> Result<ReceiptEnvelope, JournalRuntimeEntryReceiptWriteFailure> {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .success(.empty) }
    guard let data = try? Data(contentsOf: fileURL) else { return .failure(.canonicalReadFailed) }
    return decodeEnvelope(data)
}

private func encodeEnvelope(_ envelope: ReceiptEnvelope) -> Data? {
    let attempts = envelope.attempts.map { attempt in
        ["attempt_id": attempt.attemptID.rawValue, "records": attempt.records.compactMap(recordObject)] as [String: Any]
    }
    return try? JSONSerialization.data(withJSONObject: [
        "schema_version": receiptSchemaVersion,
        "attempts": attempts
    ], options: [.sortedKeys])
}

private func encodedRecordSize(_ record: JournalRuntimeEntryReceipt) -> Int {
    guard let object = recordObject(record), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return .max
    }
    return data.count
}

private func recordObject(_ record: JournalRuntimeEntryReceipt) -> [String: Any]? {
    func common(
        kind: JournalRuntimeEntryReceiptKind,
        sequence: UInt64,
        attemptID: JournalRuntimeEntryAttemptID,
        observedAt: Int64,
        identity: JournalRuntimeEntryReceiptAppIdentity
    ) -> [String: Any] {
        [
            "schema_version": receiptSchemaVersion,
            "kind": kind.rawValue,
            "attempt_id": attemptID.rawValue,
            "sequence": sequence,
            "observed_at_unix_ms": observedAt,
            "app_pid": identity.appPID,
            "app_kernel_start_time_us": identity.appKernelStartTimeMicroseconds,
            "bundle_identifier": identity.bundleIdentifier,
            "bundle_short_version": identity.bundleShortVersion,
            "bundle_version": identity.bundleVersion,
            "location_class": identity.locationClass.rawValue
        ]
    }

    switch record {
    case .outerEntry(let entry):
        return common(
            kind: .outerEntry,
            sequence: entry.sequence,
            attemptID: entry.draft.attemptID,
            observedAt: entry.draft.observedAtUnixMilliseconds,
            identity: entry.draft.appIdentity
        )
    case .payloadEntry(let entry):
        var result = common(
            kind: .payloadEntry,
            sequence: entry.sequence,
            attemptID: entry.draft.attemptID,
            observedAt: entry.draft.observedAtUnixMilliseconds,
            identity: entry.draft.appIdentity
        )
        result["generation"] = entry.draft.generation
        result["child_pid"] = entry.draft.childPID
        result["child_kernel_start_time_us"] = entry.draft.childKernelStartTimeMicroseconds
        result["candidate_provenance"] = provenanceObject(entry.draft.provenance)
        return result
    case .payloadExit(let entry):
        var result = common(
            kind: .payloadExit,
            sequence: entry.sequence,
            attemptID: entry.draft.attemptID,
            observedAt: entry.draft.observedAtUnixMilliseconds,
            identity: entry.draft.appIdentity
        )
        result["generation"] = entry.draft.generation
        result["child_pid"] = entry.draft.childPID
        result["child_kernel_start_time_us"] = entry.draft.childKernelStartTimeMicroseconds
        result["terminal_observed"] = true
        result["expected_stop"] = entry.draft.expectedStop
        result["termination_status"] = entry.draft.terminationStatus
        return result
    }
}

private func provenanceObject(_ provenance: JournalRuntimeEntryCandidateProvenance) -> [String: Any] {
    [
        "source": provenance.source,
        "target": [
            "bundle_identifier": provenance.target.bundleIdentifier,
            "bundle_short_version": provenance.target.bundleShortVersion,
            "bundle_version": provenance.target.bundleVersion
        ],
        "runtime_archive_sha256": provenance.runtimeArchiveSHA256,
        "manifest_sha256": provenance.manifestSHA256,
        "release_receipt_sha256": provenance.releaseReceiptSHA256,
        "signing_receipt_sha256": provenance.signingReceiptSHA256,
        "runtime_tree_sha256": provenance.runtimeTreeSHA256
    ]
}

private func decodeEnvelope(_ data: Data) -> Result<ReceiptEnvelope, JournalRuntimeEntryReceiptWriteFailure> {
    guard data.count <= maximumReceiptFileBytes, let object = strictJSONObject(data),
          Set(object.keys) == ["schema_version", "attempts"],
          receiptInteger(object["schema_version"], as: Int.self) == receiptSchemaVersion,
          let rawAttempts = object["attempts"] as? [[String: Any]], rawAttempts.count <= maximumReceiptAttempts else {
        return .failure(.canonicalInvalid)
    }
    var attempts: [ReceiptAttempt] = []
    var ids = Set<JournalRuntimeEntryAttemptID>()
    for rawAttempt in rawAttempts {
        guard Set(rawAttempt.keys) == ["attempt_id", "records"],
              let rawID = rawAttempt["attempt_id"] as? String,
              let id = JournalRuntimeEntryAttemptID(rawValue: rawID),
              ids.insert(id).inserted,
              let rawRecords = rawAttempt["records"] as? [[String: Any]],
              !rawRecords.isEmpty else {
            return .failure(.canonicalInvalid)
        }
        var records: [JournalRuntimeEntryReceipt] = []
        for rawRecord in rawRecords {
            guard let record = parseRecord(rawRecord), encodedRecordSize(record) <= maximumReceiptRecordBytes else {
                return .failure(.canonicalInvalid)
            }
            records.append(record)
        }
        let attempt = ReceiptAttempt(attemptID: id, records: records)
        if case .invalid = JournalRuntimeEntryReceiptChainValidator.validateAttempt(attempt) {
            return .failure(.canonicalInvalid)
        }
        attempts.append(attempt)
    }
    return .success(ReceiptEnvelope(attempts: attempts))
}

private func parseRecord(_ object: [String: Any]) -> JournalRuntimeEntryReceipt? {
    let common = [
        "schema_version", "kind", "attempt_id", "sequence", "observed_at_unix_ms", "app_pid",
        "app_kernel_start_time_us", "bundle_identifier", "bundle_short_version", "bundle_version", "location_class"
    ]
    guard receiptInteger(object["schema_version"], as: Int.self) == receiptSchemaVersion,
          let rawKind = object["kind"] as? String,
          let kind = JournalRuntimeEntryReceiptKind(rawValue: rawKind),
          let rawID = object["attempt_id"] as? String,
          let attemptID = JournalRuntimeEntryAttemptID(rawValue: rawID),
          let sequence = receiptInteger(object["sequence"], as: UInt64.self),
          let observedAt = receiptInteger(object["observed_at_unix_ms"], as: Int64.self), observedAt >= 0,
          let appPID = receiptInteger(object["app_pid"], as: Int32.self), appPID > 0,
          let appKernelStart = receiptInteger(object["app_kernel_start_time_us"], as: Int64.self), appKernelStart > 0,
          let bundleIdentifier = receiptString(object["bundle_identifier"]),
          let bundleShortVersion = receiptString(object["bundle_short_version"]),
          let bundleVersion = receiptString(object["bundle_version"]),
          let rawLocation = object["location_class"] as? String,
          let location = JournalRuntimeEntryLocationClass(rawValue: rawLocation) else {
        return nil
    }
    let identity = JournalRuntimeEntryReceiptAppIdentity(
        appPID: appPID,
        bundleIdentifier: bundleIdentifier,
        bundleShortVersion: bundleShortVersion,
        bundleVersion: bundleVersion,
        locationClass: location,
        appKernelStartTimeMicroseconds: appKernelStart
    )
    switch kind {
    case .outerEntry:
        guard Set(object.keys) == Set(common) else { return nil }
        return .outerEntry(.init(sequence: sequence, draft: .init(
            attemptID: attemptID, observedAtUnixMilliseconds: observedAt, appIdentity: identity
        )))
    case .payloadEntry:
        let allowed = common + ["generation", "child_pid", "child_kernel_start_time_us", "candidate_provenance"]
        guard Set(object.keys) == Set(allowed),
              let generation = receiptInteger(object["generation"], as: UInt64.self), generation > 0,
              let childPID = receiptInteger(object["child_pid"], as: Int32.self), childPID > 0,
              let start = receiptInteger(object["child_kernel_start_time_us"], as: Int64.self), start > 0,
              let rawProvenance = object["candidate_provenance"] as? [String: Any],
              let provenance = parseProvenance(rawProvenance) else { return nil }
        return .payloadEntry(.init(sequence: sequence, draft: .init(
            attemptID: attemptID, observedAtUnixMilliseconds: observedAt, appIdentity: identity,
            generation: generation, childPID: childPID, childKernelStartTimeMicroseconds: start, provenance: provenance
        )))
    case .payloadExit:
        let allowed = common + ["generation", "child_pid", "child_kernel_start_time_us", "terminal_observed", "expected_stop", "termination_status"]
        guard Set(object.keys) == Set(allowed),
              let generation = receiptInteger(object["generation"], as: UInt64.self), generation > 0,
              let childPID = receiptInteger(object["child_pid"], as: Int32.self), childPID > 0,
              let start = receiptInteger(object["child_kernel_start_time_us"], as: Int64.self), start > 0,
              object["terminal_observed"] as? Bool == true,
              let expectedStop = object["expected_stop"] as? Bool,
              let status = receiptInteger(object["termination_status"], as: Int32.self) else { return nil }
        return .payloadExit(.init(sequence: sequence, draft: .init(
            attemptID: attemptID, observedAtUnixMilliseconds: observedAt, appIdentity: identity,
            generation: generation, childPID: childPID, childKernelStartTimeMicroseconds: start,
            expectedStop: expectedStop, terminationStatus: status
        )))
    }
}

private func parseProvenance(_ object: [String: Any]) -> JournalRuntimeEntryCandidateProvenance? {
    let allowed = [
        "source", "target", "runtime_archive_sha256", "manifest_sha256", "release_receipt_sha256",
        "signing_receipt_sha256", "runtime_tree_sha256"
    ]
    guard Set(object.keys) == Set(allowed), object["source"] as? String == "J",
          let target = object["target"] as? [String: Any],
          Set(target.keys) == ["bundle_identifier", "bundle_short_version", "bundle_version"],
          let targetID = receiptString(target["bundle_identifier"]),
          let targetShort = receiptString(target["bundle_short_version"]),
          let targetBuild = receiptString(target["bundle_version"]),
          let runtime = receiptDigest(object["runtime_archive_sha256"]),
          let manifest = receiptDigest(object["manifest_sha256"]),
          let release = receiptDigest(object["release_receipt_sha256"]),
          let signing = receiptDigest(object["signing_receipt_sha256"]),
          let tree = receiptDigest(object["runtime_tree_sha256"]) else { return nil }
    return .init(
        source: "J",
        target: .init(bundleIdentifier: targetID, bundleShortVersion: targetShort, bundleVersion: targetBuild),
        runtimeArchiveSHA256: runtime,
        manifestSHA256: manifest,
        releaseReceiptSHA256: release,
        signingReceiptSHA256: signing,
        runtimeTreeSHA256: tree
    )
}

private func receiptString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func receiptDigest(_ value: Any?) -> String? {
    guard let value = value as? String, value.count == 64,
          value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
    return value
}

private func receiptInteger<T: FixedWidthInteger>(_ value: Any?, as _: T.Type) -> T? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded() == double else { return nil }
    return T(exactly: double)
}

private func storageBaseIsAllowed(_ baseURL: URL) -> Bool {
    let normalized = WatchdogAppLocationEligibility.normalized(baseURL)
    let disallowed = [
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
        FileManager.default.temporaryDirectory,
        URL(fileURLWithPath: "/private/tmp", isDirectory: true),
        URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
    ].map(WatchdogAppLocationEligibility.normalized)
    return !disallowed.contains { storageBase(normalized, isSameAsOrContainedBy: $0) }
}

private func storageBase(_ candidate: URL, isSameAsOrContainedBy container: URL) -> Bool {
    let candidateComponents = candidate.pathComponents
    let containerComponents = container.pathComponents
    guard candidateComponents.count >= containerComponents.count else { return false }
    return candidateComponents.starts(with: containerComponents)
}
