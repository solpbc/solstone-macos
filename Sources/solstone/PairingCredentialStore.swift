// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

public enum PairingCredentialStoreError: Error, Equatable, Sendable {
    case staleGeneration
    case noPairingFound
    case underlying(String)
}

public protocol PairingStoring: Sendable {
    func load() throws -> StoredPairing?
    func save(_ pairing: StoredPairing) throws
    func delete() throws
}

extension SPLKeychainStore: PairingStoring {}

public final class PairingCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private let store: any PairingStoring
    private var storedPairingGeneration: UInt64 = 1
    private var storedAccessGeneration: UInt64 = 1
    private var cachedPairing: StoredPairing?
    private var lastIdentityToken: String?

    public init(store: any PairingStoring) {
        self.store = store
    }

    public var pairingGeneration: UInt64 { lock.withLock { storedPairingGeneration } }
    public var accessMutationGeneration: UInt64 { lock.withLock { storedAccessGeneration } }

    public func matches(pairing: UInt64, access: UInt64) -> Bool {
        lock.withLock { storedPairingGeneration == pairing && storedAccessGeneration == access }
    }

    public func currentPairing() -> StoredPairing? {
        lock.withLock { cachedPairing }
    }

    public func currentGenerations() -> (pairingGeneration: UInt64, accessMutationGeneration: UInt64) {
        lock.withLock { (storedPairingGeneration, storedAccessGeneration) }
    }

    public func load() throws -> StoredPairing? {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try store.load()
        let previous = cachedPairing
        cachedPairing = loaded
        let identity = loaded.map { self.deriveIdentityToken(for: $0) }
        if identity != lastIdentityToken {
            lastIdentityToken = identity
            storedPairingGeneration &+= 1
            storedAccessGeneration &+= 1
        } else if loaded != previous {
            storedAccessGeneration &+= 1
        }
        return loaded
    }

    public func save(_ pairing: StoredPairing, expectedGeneration: UInt64? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        if let expectedGeneration, expectedGeneration != storedPairingGeneration {
            throw PairingCredentialStoreError.staleGeneration
        }
        try store.save(pairing)
        cachedPairing = pairing
        lastIdentityToken = deriveIdentityToken(for: pairing)
        storedPairingGeneration &+= 1
        storedAccessGeneration &+= 1
    }

    public func delete(expectedGeneration: UInt64? = nil, expectedAccessGeneration: UInt64? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        if let expectedGeneration, expectedGeneration != storedPairingGeneration {
            throw PairingCredentialStoreError.staleGeneration
        }
        if let expectedAccessGeneration, expectedAccessGeneration != storedAccessGeneration {
            throw PairingCredentialStoreError.staleGeneration
        }
        try store.delete()
        cachedPairing = nil
        lastIdentityToken = nil
        storedPairingGeneration &+= 1
        storedAccessGeneration &+= 1
    }

    public func updateRelayAccess(
        expectedPairingGen: UInt64,
        expectedAccessGen: UInt64,
        relayOrigin: String,
        deviceToken: String,
        expiresAtString: String?,
        beforeSave: () throws -> Void = {}
    ) throws -> (pairing: StoredPairing, newAccessGen: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard expectedPairingGen == storedPairingGeneration,
              expectedAccessGen == storedAccessGeneration else {
            throw PairingCredentialStoreError.staleGeneration
        }
        guard let existing = cachedPairing ?? (try? store.load()) else {
            throw PairingCredentialStoreError.noPairingFound
        }

        let updated = StoredPairing(
            instanceID: existing.instanceID,
            homeLabel: existing.homeLabel,
            relayEndpoint: relayOrigin,
            fingerprint: existing.fingerprint,
            clientCertPEM: existing.clientCertPEM,
            clientKeyPEM: existing.clientKeyPEM,
            caChainPEM: existing.caChainPEM,
            relayEnrollment: .enrolled(deviceToken: deviceToken, expiresAt: expiresAtString),
            localEndpoints: existing.localEndpoints,
            pairedAt: existing.pairedAt
        )

        try beforeSave()
        try store.save(updated)
        cachedPairing = updated
        lastIdentityToken = deriveIdentityToken(for: updated)
        storedAccessGeneration &+= 1
        return (pairing: updated, newAccessGen: storedAccessGeneration)
    }

    public func clearRelayAccess(
        expectedPairingGen: UInt64,
        expectedAccessGen: UInt64
    ) throws -> (pairing: StoredPairing, newAccessGen: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard expectedPairingGen == storedPairingGeneration,
              expectedAccessGen == storedAccessGeneration else {
            throw PairingCredentialStoreError.staleGeneration
        }
        guard let existing = cachedPairing ?? (try? store.load()) else {
            throw PairingCredentialStoreError.noPairingFound
        }

        let updated = StoredPairing(
            instanceID: existing.instanceID,
            homeLabel: existing.homeLabel,
            relayEndpoint: existing.relayEndpoint,
            fingerprint: existing.fingerprint,
            clientCertPEM: existing.clientCertPEM,
            clientKeyPEM: existing.clientKeyPEM,
            caChainPEM: existing.caChainPEM,
            relayEnrollment: .unavailable,
            localEndpoints: existing.localEndpoints,
            pairedAt: existing.pairedAt
        )

        try store.save(updated)
        cachedPairing = updated
        lastIdentityToken = deriveIdentityToken(for: updated)
        storedAccessGeneration &+= 1
        return (pairing: updated, newAccessGen: storedAccessGeneration)
    }

    public func noteExternalPairingChange(_ pairing: StoredPairing?) {
        lock.lock()
        defer { lock.unlock() }
        cachedPairing = pairing
        lastIdentityToken = pairing.map { self.deriveIdentityToken(for: $0) }
        storedPairingGeneration &+= 1
        storedAccessGeneration &+= 1
    }

    private func deriveIdentityToken(for pairing: StoredPairing) -> String {
        [pairing.instanceID, pairing.clientCertPEM, pairing.clientKeyPEM, pairing.caChainPEM, String(pairing.pairedAt.timeIntervalSince1970)].joined(separator: "\u{0}")
    }
}
