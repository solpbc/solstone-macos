// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct SetupHandoff: Codable, Sendable, Equatable {
    public static let schemaV1 = "solstone.setup-handoff.v1"

    public let schema: String
    public let handoffID: UUID
    public let stepIndex: Int
    public let journalRootPath: String?
    public let expectedInstanceID: String?
    public let expectedCAFingerprint: String?

    public init(
        handoffID: UUID,
        stepIndex: Int,
        journalRootPath: String? = nil,
        expectedInstanceID: String? = nil,
        expectedCAFingerprint: String? = nil
    ) {
        self.schema = Self.schemaV1
        self.handoffID = handoffID
        self.stepIndex = stepIndex
        self.journalRootPath = journalRootPath
        self.expectedInstanceID = expectedInstanceID
        self.expectedCAFingerprint = expectedCAFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case handoffID
        case stepIndex
        case journalRootPath
        case expectedInstanceID
        case expectedCAFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try container.decode(String.self, forKey: .schema)
        let idString = try container.decode(String.self, forKey: .handoffID)
        guard let parsedID = UUID(uuidString: idString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .handoffID,
                in: container,
                debugDescription: "handoffID must be a valid UUID"
            )
        }
        self.handoffID = parsedID
        self.stepIndex = try container.decode(Int.self, forKey: .stepIndex)
        self.journalRootPath = try container.decodeIfPresent(String.self, forKey: .journalRootPath)
        self.expectedInstanceID = try container.decodeIfPresent(String.self, forKey: .expectedInstanceID)
        self.expectedCAFingerprint = try container.decodeIfPresent(String.self, forKey: .expectedCAFingerprint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(handoffID.uuidString.lowercased(), forKey: .handoffID)
        try container.encode(stepIndex, forKey: .stepIndex)
        try container.encodeIfPresent(journalRootPath, forKey: .journalRootPath)
        try container.encodeIfPresent(expectedInstanceID, forKey: .expectedInstanceID)
        try container.encodeIfPresent(expectedCAFingerprint, forKey: .expectedCAFingerprint)
    }

    public var isValidStep1Payload: Bool {
        schema == Self.schemaV1 && stepIndex == 1
    }

    public var isValidStep5Payload: Bool {
        guard schema == Self.schemaV1, stepIndex == 5 else { return false }
        guard let root = journalRootPath, !root.isEmpty, root.hasPrefix("/") else { return false }
        guard let instance = expectedInstanceID, !instance.isEmpty else { return false }
        guard let fingerprint = expectedCAFingerprint,
              fingerprint.count == 64,
              fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return false
        }
        return true
    }
}

public struct SetupHandoffReceipt: Codable, Sendable, Equatable {
    public static let schemaV1 = "solstone.setup-handoff-accepted.v1"

    public let schema: String
    public let handoffID: UUID
    public let stepIndex: Int

    public init(handoffID: UUID, stepIndex: Int) {
        self.schema = Self.schemaV1
        self.handoffID = handoffID
        self.stepIndex = stepIndex
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case handoffID
        case stepIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try container.decode(String.self, forKey: .schema)
        let idString = try container.decode(String.self, forKey: .handoffID)
        guard let parsedID = UUID(uuidString: idString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .handoffID,
                in: container,
                debugDescription: "handoffID must be a valid UUID"
            )
        }
        self.handoffID = parsedID
        self.stepIndex = try container.decode(Int.self, forKey: .stepIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(handoffID.uuidString.lowercased(), forKey: .handoffID)
        try container.encode(stepIndex, forKey: .stepIndex)
    }
}

public enum SetupHandoffRefusalReason: String, Codable, Sendable {
    case heldPairing = "held_pairing"
    case continuationInProgress = "continuation_in_progress"

    var rejection: SetupHandoffRejection {
        self == .heldPairing ? .heldPairing : .continuationInProgress
    }
}

public struct SetupHandoffRefusal: Codable, Sendable, Equatable {
    public static let schemaV1 = "solstone.setup-handoff-refused.v1"
    public let schema: String
    public let handoffID: UUID
    public let stepIndex: Int
    public let reason: SetupHandoffRefusalReason

    public init(handoffID: UUID, reason: SetupHandoffRefusalReason) {
        schema = Self.schemaV1
        self.handoffID = handoffID
        stepIndex = 5
        self.reason = reason
    }
}

private struct SetupRefusalHistory: Codable {
    static let currentSchema = "solstone.setup-handoff-refusals.v1"
    var schema = currentSchema
    var reasons: [String: SetupHandoffRefusalReason] = [:]
}

public enum SetupStep1Load: Sendable, Equatable {
    case missing
    case malformed
    case ready(SetupHandoff)
}

public enum SetupStep5Load: Sendable, Equatable {
    case missing
    case malformed
    case ready(SetupHandoff)
}

public enum SetupHandoffRejection: Sendable, Equatable {
    case malformed
    case wrongStep
    case heldPairing
    case superseded
    case continuationInProgress
}

public enum SetupCommitResult: Sendable, Equatable {
    case accepted
    case republished
    case noHandoff
    case rejected(SetupHandoffRejection)
    case lockTimeout
}

public struct SetupMailboxStore: Sendable {
    public let directory: URL
    private let replace: @Sendable (Data, URL) throws -> Void
    private let remove: @Sendable (URL) throws -> Void

    public static let defaultDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("sol", isDirectory: true)
    }()

    public init(directory: URL = SetupMailboxStore.defaultDirectory) {
        self.directory = directory
        self.replace = { try setupAtomicReplace(data: $0, to: $1) }
        self.remove = { try FileManager.default.removeItem(at: $0) }
    }

    public init(
        directory: URL,
        replace: @escaping @Sendable (Data, URL) throws -> Void,
        remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.directory = directory
        self.replace = replace
        self.remove = remove
    }

    private var outboundHandoffURL: URL {
        directory.appendingPathComponent("journal-setup-handoff.json")
    }

    private var outboundReceiptURL: URL {
        directory.appendingPathComponent("journal-setup-handoff-accepted.json")
    }

    private var outboundLockURL: URL {
        directory.appendingPathComponent("journal-setup-handoff.lock")
    }

    private var inboundHandoffURL: URL {
        directory.appendingPathComponent("solstone-setup-handoff.json")
    }

    private var inboundReceiptURL: URL {
        directory.appendingPathComponent("solstone-setup-handoff-accepted.json")
    }

    private var inboundLockURL: URL {
        directory.appendingPathComponent("solstone-setup-handoff.lock")
    }

    public func writeStep1(handoffID: UUID) throws {
        let payload = SetupHandoff(handoffID: handoffID, stepIndex: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let acquired = try withLock(on: outboundLockURL) {
            try replace(data, outboundHandoffURL)
        }
        guard acquired else {
            throw SetupMailboxError.lockTimeout
        }
    }

    public func loadStep1() -> SetupStep1Load {
        guard FileManager.default.fileExists(atPath: outboundHandoffURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: outboundHandoffURL),
              let handoff = try? JSONDecoder().decode(SetupHandoff.self, from: data) else {
            return .malformed
        }
        guard handoff.schema == SetupHandoff.schemaV1,
              handoff.stepIndex == 1,
              handoff.isValidStep1Payload else {
            return .malformed
        }
        return .ready(handoff)
    }

    public func readStep1Receipt() throws -> SetupHandoffReceipt? {
        guard FileManager.default.fileExists(atPath: outboundReceiptURL.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: outboundReceiptURL),
              let receipt = try? JSONDecoder().decode(SetupHandoffReceipt.self, from: data) else {
            return nil
        }
        guard receipt.schema == SetupHandoffReceipt.schemaV1, receipt.stepIndex == 1 else {
            return nil
        }
        return receipt
    }

    public func commitStep1(
        loadedID: UUID,
        alreadyAccepted: Bool,
        refuseNewAcceptance: Bool,
        storeProgress: () throws -> Void
    ) throws -> SetupCommitResult {
        var result: SetupCommitResult = .lockTimeout
        let acquired = try withLock(on: outboundLockURL) {
            result = try performCommitUnderLock(
                payloadURL: outboundHandoffURL,
                receiptURL: outboundReceiptURL,
                stepIndex: 1,
                validator: { $0.isValidStep1Payload },
                loadedID: loadedID,
                alreadyAccepted: alreadyAccepted,
                refuseNewAcceptance: refuseNewAcceptance,
                storeProgress: storeProgress
            )
        }
        return acquired ? result : .lockTimeout
    }

    public func loadStep5() -> SetupStep5Load {
        guard FileManager.default.fileExists(atPath: inboundHandoffURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: inboundHandoffURL),
              let handoff = try? JSONDecoder().decode(SetupHandoff.self, from: data) else {
            return .malformed
        }
        guard handoff.schema == SetupHandoff.schemaV1,
              handoff.stepIndex == 5,
              handoff.isValidStep5Payload else {
            return .malformed
        }
        return .ready(handoff)
    }

    public func writeStep5(_ handoff: SetupHandoff) throws {
        guard handoff.isValidStep5Payload else {
            throw SetupMailboxError.malformedPayload
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(handoff)
        let acquired = try withLock(on: inboundLockURL) {
            try replace(data, inboundHandoffURL)
        }
        guard acquired else {
            throw SetupMailboxError.lockTimeout
        }
    }

    public func readStep5Receipt() throws -> SetupHandoffReceipt? {
        guard FileManager.default.fileExists(atPath: inboundReceiptURL.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: inboundReceiptURL),
              let receipt = try? JSONDecoder().decode(SetupHandoffReceipt.self, from: data) else {
            return nil
        }
        guard receipt.schema == SetupHandoffReceipt.schemaV1, receipt.stepIndex == 5 else {
            return nil
        }
        return receipt
    }

    private var refusalURL: URL { directory.appendingPathComponent("solstone-setup-handoff-refused.json") }
    private var refusalHistoryURL: URL { directory.appendingPathComponent("solstone-setup-handoff-refusals.json") }

    public func readStep5Refusal() throws -> SetupHandoffRefusal? {
        guard let data = try? Data(contentsOf: refusalURL),
              let refusal = try? JSONDecoder().decode(SetupHandoffRefusal.self, from: data),
              refusal.schema == SetupHandoffRefusal.schemaV1, refusal.stepIndex == 5 else { return nil }
        return refusal
    }

    private func refusalHistory() throws -> SetupRefusalHistory {
        let data: Data
        do { data = try Data(contentsOf: refusalHistoryURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return SetupRefusalHistory() }
        let history = try JSONDecoder().decode(SetupRefusalHistory.self, from: data)
        guard history.schema == SetupRefusalHistory.currentSchema,
              history.reasons.keys.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }) else {
            throw SetupMailboxError.malformedPayload
        }
        return history
    }

    private func publishRefusalUnderLock(_ refusal: SetupHandoffRefusal) throws -> SetupCommitResult {
        try replace(JSONEncoder().encode(refusal), refusalURL)
        if currentHandoffID(at: inboundHandoffURL) == refusal.handoffID {
            try? remove(inboundHandoffURL)
        }
        return .rejected(refusal.reason.rejection)
    }

    public func commitStep5(
        loadedID: UUID,
        alreadyAccepted: Bool,
        pairingBlocksNewAcceptance: Bool,
        refusalReason: SetupHandoffRefusalReason? = nil,
        storeProgress: () throws -> Void
    ) throws -> SetupCommitResult {
        var result: SetupCommitResult = .lockTimeout
        let acquired = try withLock(on: inboundLockURL) {
            result = try performCommitUnderLock(
                payloadURL: inboundHandoffURL,
                receiptURL: inboundReceiptURL,
                stepIndex: 5,
                validator: { $0.isValidStep5Payload },
                loadedID: loadedID,
                alreadyAccepted: alreadyAccepted,
                refuseNewAcceptance: pairingBlocksNewAcceptance,
                refusalReason: refusalReason,
                storeProgress: storeProgress
            )
        }
        return acquired ? result : .lockTimeout
    }

    private func performCommitUnderLock(
        payloadURL: URL,
        receiptURL: URL,
        stepIndex: Int,
        validator: (SetupHandoff) -> Bool,
        loadedID: UUID,
        alreadyAccepted: Bool,
        refuseNewAcceptance: Bool,
        refusalReason: SetupHandoffRefusalReason? = nil,
        storeProgress: () throws -> Void
    ) throws -> SetupCommitResult {
        guard FileManager.default.fileExists(atPath: payloadURL.path) else {
            if alreadyAccepted {
                try writeReceiptUnderLock(handoffID: loadedID, stepIndex: stepIndex, to: receiptURL)
                return .republished
            }
            return .noHandoff
        }

        let data: Data
        do {
            data = try Data(contentsOf: payloadURL)
        } catch {
            return .rejected(.malformed)
        }

        let handoff: SetupHandoff
        do {
            handoff = try JSONDecoder().decode(SetupHandoff.self, from: data)
        } catch {
            return .rejected(.malformed)
        }

        guard handoff.schema == SetupHandoff.schemaV1 else {
            return .rejected(.malformed)
        }
        guard handoff.stepIndex == stepIndex else {
            return .rejected(.wrongStep)
        }
        guard validator(handoff) else {
            return .rejected(.malformed)
        }

        if handoff.handoffID != loadedID {
            return .rejected(.superseded)
        }

        if alreadyAccepted {
            try writeReceiptUnderLock(handoffID: loadedID, stepIndex: stepIndex, to: receiptURL)
            if currentHandoffID(at: payloadURL) == loadedID {
                try? FileManager.default.removeItem(at: payloadURL)
            }
            return .republished
        }

        if stepIndex == 5 {
            var history = try refusalHistory()
            let key = loadedID.uuidString.lowercased()
            if let reason = history.reasons[key] {
                return try publishRefusalUnderLock(SetupHandoffRefusal(handoffID: loadedID, reason: reason))
            }
            if let refusalReason {
                history.reasons[key] = refusalReason
                // The decision precedes the public response, so a crash cannot forget an observed refusal.
                try replace(JSONEncoder().encode(history), refusalHistoryURL)
                return try publishRefusalUnderLock(SetupHandoffRefusal(handoffID: loadedID, reason: refusalReason))
            }
        }

        if refuseNewAcceptance { return .rejected(.heldPairing) }

        do {
            try storeProgress()
        } catch SetupMailboxError.continuationInProgress {
            return .rejected(.continuationInProgress)
        } catch {
            throw error
        }

        if currentHandoffID(at: payloadURL) != loadedID {
            return .rejected(.superseded)
        }

        try writeReceiptUnderLock(handoffID: loadedID, stepIndex: stepIndex, to: receiptURL)

        if currentHandoffID(at: payloadURL) == loadedID {
            try? FileManager.default.removeItem(at: payloadURL)
        }

        return .accepted
    }

    private func currentHandoffID(at fileURL: URL) -> UUID? {
        guard let data = try? Data(contentsOf: fileURL),
              let handoff = try? JSONDecoder().decode(SetupHandoff.self, from: data) else {
            return nil
        }
        return handoff.handoffID
    }

    private func writeReceiptUnderLock(handoffID: UUID, stepIndex: Int, to destination: URL) throws {
        let receipt = SetupHandoffReceipt(handoffID: handoffID, stepIndex: stepIndex)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        try replace(data, destination)
    }

    @discardableResult
    private func withLock(on lockURL: URL, action: () throws -> Void) throws -> Bool {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            return false
        }
        defer {
            close(fd)
        }

        let deadline = Date().addingTimeInterval(2.0)
        var acquired = false
        while Date() < deadline {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            let err = errno
            if err != EWOULDBLOCK && err != EAGAIN {
                return false
            }
            usleep(50_000)
        }

        guard acquired else {
            return false
        }

        defer {
            flock(fd, LOCK_UN)
        }

        try action()
        return true
    }
}

package func setupAtomicReplace(
    data: Data,
    to destination: URL,
    sync: (Int32) -> Int32 = { fsync($0) }
) throws {
    let parentDir = destination.deletingLastPathComponent()
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: parentDir.path, isDirectory: &isDir)
    if exists && !isDir.boolValue {
        throw POSIXError(.ENOTDIR)
    }
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    let tempURL = parentDir.appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
    try data.write(to: tempURL)

    let fd = open(tempURL.path, O_RDONLY)
    guard fd >= 0 else {
        let err = errno
        try? FileManager.default.removeItem(at: tempURL)
        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
    let syncRes = sync(fd)
    close(fd)
    guard syncRes == 0 else {
        let err = errno
        try? FileManager.default.removeItem(at: tempURL)
        throw POSIXError(POSIXErrorCode(rawValue: err != 0 ? err : EIO) ?? .EIO)
    }

    if Darwin.rename(tempURL.path, destination.path) != 0 {
        let err = errno
        try? FileManager.default.removeItem(at: tempURL)
        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
}

public enum SetupMailboxError: Error, Sendable, Equatable {
    case lockTimeout
    case continuationInProgress
    case malformedPayload
}

public func journalSupportsSetupSequence(_ raw: Any?) -> Bool {
    guard let array = raw as? [String] else { return false }
    return array.contains("setup-sequence-v1")
}
