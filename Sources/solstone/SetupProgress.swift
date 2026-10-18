// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

public enum SetupPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case journal
    case microphone
    case screen
    case connection
}

public enum SetupMode: String, Codable, Sendable, Equatable {
    case supporting
    case ownerComparison
}

public struct SetupAcceptedStep5Snapshot: Codable, Sendable, Equatable {
    public let handoffID: UUID
    public let journalRootPath: String
    public let expectedInstanceID: String
    public let expectedCAFingerprint: String

    public init(
        handoffID: UUID,
        journalRootPath: String,
        expectedInstanceID: String,
        expectedCAFingerprint: String
    ) {
        self.handoffID = handoffID
        self.journalRootPath = journalRootPath
        self.expectedInstanceID = expectedInstanceID
        self.expectedCAFingerprint = expectedCAFingerprint
    }

    public var isValid: Bool {
        guard !journalRootPath.isEmpty, journalRootPath.hasPrefix("/") else { return false }
        guard !expectedInstanceID.isEmpty else { return false }
        guard expectedCAFingerprint.count == 64,
              expectedCAFingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return false
        }
        return true
    }
}

public struct SetupContinuation: Codable, Sendable, Equatable {
    public var phase: SetupPhase?
    public var pendingOutboundStep1ID: UUID?
    public var accepted: SetupAcceptedStep5Snapshot?
    public var mode: SetupMode?
    public var completed: Bool

    public init(
        phase: SetupPhase? = nil,
        pendingOutboundStep1ID: UUID? = nil,
        accepted: SetupAcceptedStep5Snapshot? = nil,
        mode: SetupMode? = nil,
        completed: Bool = false
    ) {
        self.phase = phase
        self.pendingOutboundStep1ID = pendingOutboundStep1ID
        self.accepted = accepted
        self.mode = mode
        self.completed = completed
    }
}

public struct SetupContinuationStore: Sendable {
    public let directory: URL
    public let fileURL: URL
    private let replace: @Sendable (Data, URL) throws -> Void

    public static let defaultDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("sol", isDirectory: true)
    }()

    public init(directory: URL = SetupContinuationStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("solstone-setup-continuation.json")
        self.replace = { try setupAtomicReplace(data: $0, to: $1) }
    }

    public init(
        directory: URL,
        replace: @escaping @Sendable (Data, URL) throws -> Void
    ) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("solstone-setup-continuation.json")
        self.replace = replace
    }

    public func load() -> SetupContinuation? {
        try? loadChecked()
    }

    public func loadChecked() throws -> SetupContinuation? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(SetupContinuation.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func save(_ record: SetupContinuation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try replace(data, fileURL)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
