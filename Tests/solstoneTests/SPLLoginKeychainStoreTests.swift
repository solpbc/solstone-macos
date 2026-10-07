// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

/// Memory-backed coverage of the login keychain store's load/save state machine:
/// first move from the Data Protection item, a credential carried to another
/// Mac without its device marker, an unreadable keychain, and an absent one.
@Suite("Login keychain pairing store")
struct SPLLoginKeychainStoreTests {
    private let paired = pairing(instanceID: "login-keychain-store")

    @Test func emptyKeychainsHoldNoPairingAndStayAbsent() throws {
        let items = MemoryPairingKeychainItems()
        let store = SPLLoginKeychainStore(items: items)
        #expect(try store.load() == nil)
        #expect(items.destination == nil)
        #expect(items.baseline == nil)
        #expect(PairingCredentialStore(store: store).admission(for: nil) == .absent)
    }

    @Test func legacyDataProtectionCredentialMovesIntoTheLoginKeychainOnce() throws {
        let legacyBytes = try encodedPairing()
        let items = MemoryPairingKeychainItems()
        items.legacy = legacyBytes
        let store = SPLLoginKeychainStore(items: items)

        #expect(try store.load() == paired)
        #expect(items.destination == legacyBytes)
        #expect(items.legacy == nil)
        #expect(items.baseline != nil)
        #expect(items.device["marker"] != nil)
        let record = try store.loadCarriedPairingRecord()
        #expect(record.completedPortableBaseline?.fingerprint == paired.fingerprint)
        #expect(record.completedPortableBaseline?.sourceProvenance == "data-protection-keychain")
        #expect(!record.legacyCleanupPending)
        #expect(PairingCredentialStore(store: store).admission(for: paired) == .ready)

        // A second launch reads the moved credential without another move.
        #expect(try SPLLoginKeychainStore(items: items).load() == paired)
        #expect(items.destination == legacyBytes)
    }

    @Test func savedCredentialReadsBackReadyOnTheSameDevice() throws {
        let items = MemoryPairingKeychainItems()
        let store = SPLLoginKeychainStore(items: items)
        try store.save(paired)
        #expect(items.destination != nil)
        #expect(items.baseline != nil)
        #expect(items.device["marker"] != nil)
        #expect(try store.load() == paired)
        #expect(PairingCredentialStore(store: store).admission(for: paired) == .ready)
    }

    @Test func carriedCredentialWithoutItsDeviceMarkerRequiresMigration() throws {
        let source = MemoryPairingKeychainItems()
        try SPLLoginKeychainStore(items: source).save(paired)

        // Migration Assistant carries the login keychain file: credential and
        // baseline arrive, the Data Protection device items do not.
        let destination = MemoryPairingKeychainItems()
        destination.destination = source.destination
        destination.baseline = source.baseline
        let carried = SPLLoginKeychainStore(items: destination)

        #expect(try carried.load() == paired)
        let record = try carried.loadCarriedPairingRecord()
        #expect(record.localMarker == nil)
        #expect(record.completedPortableBaseline != nil)
        #expect(PairingCredentialStore(store: carried).admission(for: paired) == .migrationRequired)
        #expect(destination.device["marker"] == nil)
    }

    @Test func destinationWithoutBaselineOrDeviceRecordIsUnreadableNotAbsent() throws {
        let items = MemoryPairingKeychainItems()
        items.destination = try encodedPairing()
        let store = SPLLoginKeychainStore(items: items)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(items.destination != nil)
    }

    @Test func unreadableKeychainIsUnavailableNotUnpaired() throws {
        let items = MemoryPairingKeychainItems()
        try SPLLoginKeychainStore(items: items).save(paired)
        items.failReads = true
        let store = SPLLoginKeychainStore(items: items)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.loadCarriedPairingRecord() }
        #expect(items.destination != nil)
    }

    @Test func conflictingDestinationAndLegacyCredentialsFailVisiblyAndKeepBoth() throws {
        let destinationBytes = try encodedPairing()
        let scratch = MemoryPairingKeychainItems()
        try SPLLoginKeychainStore(items: scratch).save(pairing(instanceID: "a-different-journal"))
        let legacyBytes = try #require(scratch.destination)
        let items = MemoryPairingKeychainItems()
        items.destination = destinationBytes
        items.legacy = legacyBytes
        let store = SPLLoginKeychainStore(items: items)

        #expect(throws: PairingKeychainError.conflictingCredentials) { try store.load() }
        #expect(throws: PairingKeychainError.conflictingCredentials) { try store.save(paired) }
        #expect(items.destination == destinationBytes)
        #expect(items.legacy == legacyBytes)
        #expect(items.baseline == nil)
    }

    @Test func absentDestinationBesideACompletedBaselineReadsAbsent() throws {
        let items = MemoryPairingKeychainItems()
        let store = SPLLoginKeychainStore(items: items)
        try store.save(paired)
        try store.delete()
        #expect(try store.load() == nil)
        #expect(PairingCredentialStore(store: store).admission(for: nil) == .absent)
    }

    private func encodedPairing() throws -> Data {
        let scratch = MemoryPairingKeychainItems()
        try SPLLoginKeychainStore(items: scratch).save(paired)
        return try #require(scratch.destination)
    }
}

final class MemoryPairingKeychainItems: PairingKeychainItems, @unchecked Sendable {
    struct Unavailable: Error {}

    private let lock = NSLock()
    private var _destination: Data?
    private var _baseline: Data?
    private var _legacy: Data?
    private var _device: [String: Data] = [:]
    private var _failReads = false

    var destination: Data? {
        get { lock.withLock { _destination } }
        set { lock.withLock { _destination = newValue } }
    }
    var baseline: Data? {
        get { lock.withLock { _baseline } }
        set { lock.withLock { _baseline = newValue } }
    }
    var legacy: Data? {
        get { lock.withLock { _legacy } }
        set { lock.withLock { _legacy = newValue } }
    }
    var device: [String: Data] { lock.withLock { _device } }
    var failReads: Bool {
        get { lock.withLock { _failReads } }
        set { lock.withLock { _failReads = newValue } }
    }

    private func read(_ value: Data?) throws -> Data? {
        if failReads { throw Unavailable() }
        return value
    }

    func readDestination() throws -> Data? { try read(destination) }
    func writeDestination(_ data: Data) throws { destination = data }
    func deleteDestination() throws { destination = nil }
    func readPortableBaseline() throws -> Data? { try read(baseline) }
    func writePortableBaseline(_ data: Data) throws { baseline = data }
    func deletePortableBaseline() throws { baseline = nil }
    func readLegacy() throws -> Data? { try read(legacy) }
    func deleteLegacy() throws { legacy = nil }
    func readDeviceItem(account: String) throws -> Data? { try read(lock.withLock { _device[account] }) }
    func writeDeviceItem(account: String, data: Data) throws { lock.withLock { _device[account] = data } }
    func deleteDeviceItem(account: String) throws { _ = lock.withLock { _device.removeValue(forKey: account) } }
}
