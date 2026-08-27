// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct JournalRuntimeEntryReceiptChainValidator: Sendable {
    private let records: [JournalRuntimeEntryReceipt]

    public init(records: [JournalRuntimeEntryReceipt]) {
        self.records = records
    }

    public func validate(
        attemptID: JournalRuntimeEntryAttemptID
    ) -> JournalRuntimeEntryReceiptChainValidationResult {
        Self.validate(records, attemptID: attemptID)
    }

    static func validate(
        _ envelope: ReceiptEnvelope,
        attemptID: JournalRuntimeEntryAttemptID
    ) -> JournalRuntimeEntryReceiptChainValidationResult {
        guard let attempt = envelope.attempts.first(where: { $0.attemptID == attemptID }) else {
            return .invalid(.missingAttempt)
        }
        return validateAttempt(attempt)
    }

    static func validateAttempt(
        _ attempt: ReceiptAttempt
    ) -> JournalRuntimeEntryReceiptChainValidationResult {
        validate(attempt.records, attemptID: attempt.attemptID)
    }

    static func isClosed(_ attempt: ReceiptAttempt) -> Bool {
        if case .validClosed = validateAttempt(attempt) {
            return true
        }
        return false
    }

    private static func validate(
        _ records: [JournalRuntimeEntryReceipt],
        attemptID: JournalRuntimeEntryAttemptID
    ) -> JournalRuntimeEntryReceiptChainValidationResult {
        guard let first = records.first else {
            return .invalid(.missingOuterEntry)
        }
        guard case let .outerEntry(outer) = first else {
            return .invalid(.missingOuterEntry)
        }

        var payloadEntries: [UInt64: JournalRuntimeEntryReceiptPayloadEntry] = [:]
        var payloadExits = Set<UInt64>()
        let outerIdentity = outer.draft.appIdentity

        for (index, record) in records.enumerated() {
            guard record.sequence == UInt64(index), record.attemptID == attemptID else {
                return .invalid(record.attemptID == attemptID ? .reorderedRecord : .crossAttemptRecord)
            }

            switch record {
            case let .outerEntry(entry):
                guard index == 0 else { return .invalid(.duplicateOuterEntry) }
                guard entry.draft.appIdentity == outerIdentity else { return .invalid(.inconsistentAppIdentity) }
                guard entry.draft.appIdentity.appKernelStartTimeMicroseconds > 0 else {
                    return .invalid(.malformed)
                }

            case let .payloadEntry(entry):
                guard entry.draft.appIdentity == outerIdentity else { return .invalid(.inconsistentAppIdentity) }
                guard entry.draft.generation > 0,
                      entry.draft.childPID > 0,
                      entry.draft.childKernelStartTimeMicroseconds > 0 else {
                    return .invalid(.malformed)
                }
                guard entry.draft.provenance.target.bundleIdentifier == outerIdentity.bundleIdentifier,
                      entry.draft.provenance.target.bundleShortVersion == outerIdentity.bundleShortVersion,
                      entry.draft.provenance.target.bundleVersion == outerIdentity.bundleVersion else {
                    return .invalid(.invalidProvenance)
                }
                guard payloadEntries[entry.draft.generation] == nil else {
                    return .invalid(.duplicatePayloadEntry)
                }
                payloadEntries[entry.draft.generation] = entry

            case let .payloadExit(exit):
                guard exit.draft.appIdentity == outerIdentity else { return .invalid(.inconsistentAppIdentity) }
                guard exit.draft.generation > 0,
                      exit.draft.childPID > 0,
                      exit.draft.childKernelStartTimeMicroseconds > 0 else {
                    return .invalid(.malformed)
                }
                guard let entry = payloadEntries[exit.draft.generation] else {
                    return .invalid(.missingPeer)
                }
                guard !payloadExits.contains(exit.draft.generation) else {
                    return .invalid(.duplicatePayloadExit)
                }
                guard exit.sequence > entry.sequence else { return .invalid(.reorderedRecord) }
                guard exit.draft.childPID == entry.draft.childPID else { return .invalid(.missingPeer) }
                guard exit.draft.childKernelStartTimeMicroseconds == entry.draft.childKernelStartTimeMicroseconds else {
                    return .invalid(.samePIDDifferentStartTime)
                }
                payloadExits.insert(exit.draft.generation)
            }
        }

        if payloadEntries.keys.allSatisfy(payloadExits.contains) {
            return .validClosed(records: records)
        }
        return .validOpen(records: records)
    }
}
