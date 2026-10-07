// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
@testable import solstone

enum FileBackedPairingStoreError: Error, Equatable {
    case simulatedIntentWriteFailure
    case simulatedCredentialSaveFailure
}

final class FileBackedPairingStore: PairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    let directory: URL
    private let credentialURL: URL
    private let recordURL: URL

    var failNextIntentWrite = false
    var failNextCredentialSave = false
    var blockAfterIntentDurable: (@Sendable () -> Void)?
    var blockAfterCredentialDurable: (@Sendable () -> Void)?

    init(directory: URL) {
        self.directory = directory
        self.credentialURL = directory.appendingPathComponent("credential.json")
        self.recordURL = directory.appendingPathComponent("record.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() throws -> StoredPairing? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: credentialURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: credentialURL)
        return try JSONDecoder().decode(StoredPairing.self, from: data)
    }

    func save(_ pairing: StoredPairing) throws {
        lock.lock()
        let shouldFail = failNextCredentialSave
        if shouldFail {
            failNextCredentialSave = false
        }
        let hook = blockAfterCredentialDurable
        if hook != nil {
            blockAfterCredentialDurable = nil
        }
        lock.unlock()

        if shouldFail {
            throw FileBackedPairingStoreError.simulatedCredentialSaveFailure
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pairing)

        let tmpURL = directory.appendingPathComponent("credential.tmp.\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)
        if rename(tmpURL.path, credentialURL.path) != 0 {
            let err = errno
            _ = try? FileManager.default.removeItem(at: tmpURL)
            throw POSIXError(POSIXError.Code(rawValue: err) ?? .EIO)
        }

        hook?()
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: credentialURL)
    }

    func loadCarriedPairingRecord() throws -> CarriedPairingRecord {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            return .empty
        }
        let data = try Data(contentsOf: recordURL)
        return try JSONDecoder().decode(CarriedPairingRecord.self, from: data)
    }

    func saveCarriedPairingRecord(_ record: CarriedPairingRecord) throws {
        lock.lock()
        let shouldFail = failNextIntentWrite && record.freshPairIntent != nil
        if shouldFail {
            failNextIntentWrite = false
        }
        let hook = (record.freshPairIntent != nil) ? blockAfterIntentDurable : nil
        if hook != nil {
            blockAfterIntentDurable = nil
        }
        lock.unlock()

        if shouldFail {
            throw FileBackedPairingStoreError.simulatedIntentWriteFailure
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)

        let tmpURL = directory.appendingPathComponent("record.tmp.\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)
        if rename(tmpURL.path, recordURL.path) != 0 {
            let err = errno
            _ = try? FileManager.default.removeItem(at: tmpURL)
            throw POSIXError(POSIXError.Code(rawValue: err) ?? .EIO)
        }

        hook?()
    }
}
