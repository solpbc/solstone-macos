// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

public struct JournalRuntimeEntryAttemptID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    public init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue), uuid.uuidString.lowercased() == rawValue else {
            return nil
        }
        self.rawValue = rawValue
    }
}

public enum JournalRuntimeEntryReceiptKind: String, Codable, Equatable, Sendable {
    case outerEntry = "outer-entry"
    case payloadEntry = "payload-entry"
    case payloadExit = "payload-exit"
}

public enum JournalRuntimeEntryLocationClass: String, Codable, Equatable, Sendable {
    case standard
    case translocated
    case other
}

public struct JournalRuntimeEntryReceiptAppIdentity: Equatable, Sendable {
    public let appPID: Int32
    public let bundleIdentifier: String
    public let bundleShortVersion: String
    public let bundleVersion: String
    public let locationClass: JournalRuntimeEntryLocationClass
    public let appKernelStartTimeMicroseconds: Int64

    public init(
        appPID: Int32,
        bundleIdentifier: String,
        bundleShortVersion: String,
        bundleVersion: String,
        locationClass: JournalRuntimeEntryLocationClass,
        appKernelStartTimeMicroseconds: Int64
    ) {
        self.appPID = appPID
        self.bundleIdentifier = bundleIdentifier
        self.bundleShortVersion = bundleShortVersion
        self.bundleVersion = bundleVersion
        self.locationClass = locationClass
        self.appKernelStartTimeMicroseconds = appKernelStartTimeMicroseconds
    }

    static func live(
        bundle: Bundle,
        processEvidenceLookup: @Sendable (pid_t) -> JournalProcessEvidence? = liveJournalProcessEvidence
    ) -> JournalRuntimeEntryReceiptAppIdentity? {
        guard let bundleIdentifier = bundle.bundleIdentifier?.nonEmptyTrimmed,
              let bundleShortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.nonEmptyTrimmed,
              let bundleVersion = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?.nonEmptyTrimmed else {
            return nil
        }
        let appPID = getpid()
        guard let evidence = processEvidenceLookup(appPID), evidence.pid == appPID,
              let kernelStart = evidence.kernelStartTime,
              let appKernelStartTimeMicroseconds = kernelStartTimeMicroseconds(kernelStart) else {
            return nil
        }
        return JournalRuntimeEntryReceiptAppIdentity(
            appPID: appPID,
            bundleIdentifier: bundleIdentifier,
            bundleShortVersion: bundleShortVersion,
            bundleVersion: bundleVersion,
            locationClass: JournalRuntimeEntryLocationClassifier.classify(bundleURL: bundle.bundleURL),
            appKernelStartTimeMicroseconds: appKernelStartTimeMicroseconds
        )
    }
}

public struct JournalRuntimeEntryCandidateTarget: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let bundleShortVersion: String
    public let bundleVersion: String

    public init(bundleIdentifier: String, bundleShortVersion: String, bundleVersion: String) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleShortVersion = bundleShortVersion
        self.bundleVersion = bundleVersion
    }
}

public struct JournalRuntimeEntryCandidateProvenance: Codable, Equatable, Sendable {
    public let source: String
    public let target: JournalRuntimeEntryCandidateTarget
    public let runtimeArchiveSHA256: String
    public let manifestSHA256: String
    public let releaseReceiptSHA256: String
    public let signingReceiptSHA256: String
    public let runtimeTreeSHA256: String

    public init(
        source: String,
        target: JournalRuntimeEntryCandidateTarget,
        runtimeArchiveSHA256: String,
        manifestSHA256: String,
        releaseReceiptSHA256: String,
        signingReceiptSHA256: String,
        runtimeTreeSHA256: String
    ) {
        self.source = source
        self.target = target
        self.runtimeArchiveSHA256 = runtimeArchiveSHA256
        self.manifestSHA256 = manifestSHA256
        self.releaseReceiptSHA256 = releaseReceiptSHA256
        self.signingReceiptSHA256 = signingReceiptSHA256
        self.runtimeTreeSHA256 = runtimeTreeSHA256
    }
}

public struct JournalRuntimeEntryReceiptOuterDraft: Equatable, Sendable {
    public let attemptID: JournalRuntimeEntryAttemptID
    public let observedAtUnixMilliseconds: Int64
    public let appIdentity: JournalRuntimeEntryReceiptAppIdentity

    public init(
        attemptID: JournalRuntimeEntryAttemptID,
        observedAtUnixMilliseconds: Int64,
        appIdentity: JournalRuntimeEntryReceiptAppIdentity
    ) {
        self.attemptID = attemptID
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
        self.appIdentity = appIdentity
    }
}

public struct JournalRuntimeEntryReceiptPayloadEntryDraft: Equatable, Sendable {
    public let attemptID: JournalRuntimeEntryAttemptID
    public let observedAtUnixMilliseconds: Int64
    public let appIdentity: JournalRuntimeEntryReceiptAppIdentity
    public let generation: UInt64
    public let childPID: Int32
    public let childKernelStartTimeMicroseconds: Int64
    public let provenance: JournalRuntimeEntryCandidateProvenance

    public init(
        attemptID: JournalRuntimeEntryAttemptID,
        observedAtUnixMilliseconds: Int64,
        appIdentity: JournalRuntimeEntryReceiptAppIdentity,
        generation: UInt64,
        childPID: Int32,
        childKernelStartTimeMicroseconds: Int64,
        provenance: JournalRuntimeEntryCandidateProvenance
    ) {
        self.attemptID = attemptID
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
        self.appIdentity = appIdentity
        self.generation = generation
        self.childPID = childPID
        self.childKernelStartTimeMicroseconds = childKernelStartTimeMicroseconds
        self.provenance = provenance
    }
}

public struct JournalRuntimeEntryReceiptPayloadExitDraft: Equatable, Sendable {
    public let attemptID: JournalRuntimeEntryAttemptID
    public let observedAtUnixMilliseconds: Int64
    public let appIdentity: JournalRuntimeEntryReceiptAppIdentity
    public let generation: UInt64
    public let childPID: Int32
    public let childKernelStartTimeMicroseconds: Int64
    public let expectedStop: Bool
    public let terminationStatus: Int32

    public init(
        attemptID: JournalRuntimeEntryAttemptID,
        observedAtUnixMilliseconds: Int64,
        appIdentity: JournalRuntimeEntryReceiptAppIdentity,
        generation: UInt64,
        childPID: Int32,
        childKernelStartTimeMicroseconds: Int64,
        expectedStop: Bool,
        terminationStatus: Int32
    ) {
        self.attemptID = attemptID
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
        self.appIdentity = appIdentity
        self.generation = generation
        self.childPID = childPID
        self.childKernelStartTimeMicroseconds = childKernelStartTimeMicroseconds
        self.expectedStop = expectedStop
        self.terminationStatus = terminationStatus
    }
}

public enum JournalRuntimeEntryReceiptDraft: Equatable, Sendable {
    case outerEntry(JournalRuntimeEntryReceiptOuterDraft)
    case payloadEntry(JournalRuntimeEntryReceiptPayloadEntryDraft)
    case payloadExit(JournalRuntimeEntryReceiptPayloadExitDraft)

    var attemptID: JournalRuntimeEntryAttemptID {
        switch self {
        case .outerEntry(let draft): draft.attemptID
        case .payloadEntry(let draft): draft.attemptID
        case .payloadExit(let draft): draft.attemptID
        }
    }
}

public struct JournalRuntimeEntryReceiptOuterEntry: Equatable, Sendable {
    public let sequence: UInt64
    public let draft: JournalRuntimeEntryReceiptOuterDraft
}

public struct JournalRuntimeEntryReceiptPayloadEntry: Equatable, Sendable {
    public let sequence: UInt64
    public let draft: JournalRuntimeEntryReceiptPayloadEntryDraft
}

public struct JournalRuntimeEntryReceiptPayloadExit: Equatable, Sendable {
    public let sequence: UInt64
    public let draft: JournalRuntimeEntryReceiptPayloadExitDraft
}

public enum JournalRuntimeEntryReceipt: Equatable, Sendable {
    case outerEntry(JournalRuntimeEntryReceiptOuterEntry)
    case payloadEntry(JournalRuntimeEntryReceiptPayloadEntry)
    case payloadExit(JournalRuntimeEntryReceiptPayloadExit)

    public var kind: JournalRuntimeEntryReceiptKind {
        switch self {
        case .outerEntry: .outerEntry
        case .payloadEntry: .payloadEntry
        case .payloadExit: .payloadExit
        }
    }

    public var sequence: UInt64 {
        switch self {
        case .outerEntry(let entry): entry.sequence
        case .payloadEntry(let entry): entry.sequence
        case .payloadExit(let entry): entry.sequence
        }
    }

    public var attemptID: JournalRuntimeEntryAttemptID {
        switch self {
        case .outerEntry(let entry): entry.draft.attemptID
        case .payloadEntry(let entry): entry.draft.attemptID
        case .payloadExit(let entry): entry.draft.attemptID
        }
    }
}

public enum JournalRuntimeEntryReceiptWriteFailure: String, Error, Equatable, Sendable {
    case lockTimeout
    case lockFailure
    case storageRootRejected
    case canonicalReadFailed
    case canonicalInvalid
    case recordRejected
    case boundsExceeded
    case stagingFailed
    case stagedValidationFailed
    case renameFailed
}

public enum JournalRuntimeEntryReceiptWriteResult: Equatable, Sendable {
    case recorded
    case unavailable(JournalRuntimeEntryReceiptWriteFailure)
}

public enum JournalRuntimeEntryReceiptChainInvalidReason: String, Equatable, Sendable {
    case missingAttempt
    case malformed
    case missingOuterEntry
    case duplicateOuterEntry
    case reorderedRecord
    case crossAttemptRecord
    case duplicatePayloadEntry
    case duplicatePayloadExit
    case missingPeer
    case samePIDDifferentStartTime
    case payloadIdentityMismatch
    case inconsistentAppIdentity
    case invalidProvenance
}

public enum JournalRuntimeEntryReceiptChainValidationResult: Equatable, Sendable {
    case validClosed(records: [JournalRuntimeEntryReceipt])
    case validOpen(records: [JournalRuntimeEntryReceipt])
    case invalid(JournalRuntimeEntryReceiptChainInvalidReason)
    case unavailable(JournalRuntimeEntryReceiptWriteFailure)
}

public protocol JournalRuntimeEntryReceiptChainValidating: Sendable {
    func validate(attemptID: JournalRuntimeEntryAttemptID) -> JournalRuntimeEntryReceiptChainValidationResult
}

public protocol JournalRuntimeEntryReceiptSinking: Sendable {
    func appendSynchronously(_ draft: JournalRuntimeEntryReceiptDraft) -> JournalRuntimeEntryReceiptWriteResult
    func append(_ draft: JournalRuntimeEntryReceiptDraft) async -> JournalRuntimeEntryReceiptWriteResult
}

public extension JournalRuntimeEntryReceiptSinking {
    func append(_ draft: JournalRuntimeEntryReceiptDraft) async -> JournalRuntimeEntryReceiptWriteResult {
        appendSynchronously(draft)
    }
}

public struct JournalRuntimeEntryReceiptContext: Sendable {
    public let attemptID: JournalRuntimeEntryAttemptID
    public let sink: any JournalRuntimeEntryReceiptSinking
    public let appIdentity: JournalRuntimeEntryReceiptAppIdentity?
    public let candidateProvenance: JournalRuntimeEntryCandidateProvenance?

    public init(
        attemptID: JournalRuntimeEntryAttemptID,
        sink: any JournalRuntimeEntryReceiptSinking,
        appIdentity: JournalRuntimeEntryReceiptAppIdentity?,
        candidateProvenance: JournalRuntimeEntryCandidateProvenance?
    ) {
        self.attemptID = attemptID
        self.sink = sink
        self.appIdentity = appIdentity
        self.candidateProvenance = candidateProvenance
    }

    func payloadEntryDraft(identity: SupervisedChildIdentity, now: Date = Date()) -> JournalRuntimeEntryReceiptDraft? {
        guard let appIdentity, let candidateProvenance,
              let kernelStart = kernelStartTimeMicroseconds(identity.kernelStartTime) else {
            return nil
        }
        return .payloadEntry(JournalRuntimeEntryReceiptPayloadEntryDraft(
            attemptID: attemptID,
            observedAtUnixMilliseconds: unixMilliseconds(now),
            appIdentity: appIdentity,
            generation: identity.generation,
            childPID: identity.pid,
            childKernelStartTimeMicroseconds: kernelStart,
            provenance: candidateProvenance
        ))
    }

    func payloadExitDraft(
        identity: SupervisedChildIdentity,
        expectedStop: Bool,
        terminationStatus: Int32,
        now: Date = Date()
    ) -> JournalRuntimeEntryReceiptDraft? {
        guard let appIdentity, let kernelStart = kernelStartTimeMicroseconds(identity.kernelStartTime) else {
            return nil
        }
        return .payloadExit(JournalRuntimeEntryReceiptPayloadExitDraft(
            attemptID: attemptID,
            observedAtUnixMilliseconds: unixMilliseconds(now),
            appIdentity: appIdentity,
            generation: identity.generation,
            childPID: identity.pid,
            childKernelStartTimeMicroseconds: kernelStart,
            expectedStop: expectedStop,
            terminationStatus: terminationStatus
        ))
    }
}

public enum JournalRuntimeEntryReceiptLaunch {
    public static func begin(
        bundle: Bundle = .main,
        provenanceBundle: Bundle? = nil,
        sink: (any JournalRuntimeEntryReceiptSinking)? = nil,
        applicationSupportBaseURL: URL? = nil,
        processEvidenceLookup: (@Sendable (pid_t) -> JournalProcessEvidence?)? = nil
    ) -> JournalRuntimeEntryReceiptContext {
        let receiptSink = sink ?? FileJournalRuntimeEntryReceiptSink(applicationSupportBaseURL: applicationSupportBaseURL)
        let attemptID = JournalRuntimeEntryAttemptID()
        let effectiveProcessEvidenceLookup = processEvidenceLookup ?? liveJournalProcessEvidence
        let appIdentity = JournalRuntimeEntryReceiptAppIdentity.live(
            bundle: bundle,
            processEvidenceLookup: effectiveProcessEvidenceLookup
        )
        let provenance = appIdentity.flatMap {
            BundledJournalRuntimeEntryCandidateProvenanceResolver(
                bundle: provenanceBundle ?? bundle
            ).resolve(for: $0)
        }
        let context = JournalRuntimeEntryReceiptContext(
            attemptID: attemptID,
            sink: receiptSink,
            appIdentity: appIdentity,
            candidateProvenance: provenance
        )
        if let appIdentity {
            _ = receiptSink.appendSynchronously(.outerEntry(JournalRuntimeEntryReceiptOuterDraft(
                attemptID: attemptID,
                observedAtUnixMilliseconds: unixMilliseconds(Date()),
                appIdentity: appIdentity
            )))
        }
        return context
    }
}

func unixMilliseconds(_ date: Date) -> Int64 {
    guard date.timeIntervalSince1970.isFinite else { return 0 }
    return max(0, Int64(date.timeIntervalSince1970 * 1_000))
}

func kernelStartTimeMicroseconds(_ value: Double) -> Int64? {
    guard value.isFinite, value > 0 else { return nil }
    let microseconds = value * 1_000_000
    guard microseconds.isFinite, microseconds > 0, microseconds <= Double(Int64.max) else { return nil }
    return Int64(microseconds.rounded())
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
