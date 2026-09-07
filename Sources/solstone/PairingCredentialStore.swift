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
    private(set) var pairingGeneration: UInt64 = 1
    private(set) var accessMutationGeneration: UInt64 = 1
    private var cachedPairing: StoredPairing?
    private var lastIdentityToken: String?

    public init(store: any PairingStoring) {
        self.store = store
    }

    public func currentPairing() -> StoredPairing? {
        lock.withLock { cachedPairing }
    }

    public func currentGenerations() -> (pairingGeneration: UInt64, accessMutationGeneration: UInt64) {
        lock.withLock { (pairingGeneration, accessMutationGeneration) }
    }

    public func load() throws -> StoredPairing? {
        lock.lock()
        defer { lock.unlock() }
        let loaded = try store.load()
        cachedPairing = loaded
        let identity = loaded.map { self.deriveIdentityToken(for: $0) }
        if identity != lastIdentityToken {
            lastIdentityToken = identity
            pairingGeneration &+= 1
            accessMutationGeneration &+= 1
        }
        return loaded
    }

    public func save(_ pairing: StoredPairing, expectedGeneration: UInt64? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        if let expectedGeneration, expectedGeneration != pairingGeneration {
            throw PairingCredentialStoreError.staleGeneration
        }
        try store.save(pairing)
        cachedPairing = pairing
        lastIdentityToken = deriveIdentityToken(for: pairing)
        pairingGeneration &+= 1
        accessMutationGeneration &+= 1
    }

    public func delete(expectedGeneration: UInt64? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        if let expectedGeneration, expectedGeneration != pairingGeneration {
            throw PairingCredentialStoreError.staleGeneration
        }
        try store.delete()
        cachedPairing = nil
        lastIdentityToken = nil
        pairingGeneration &+= 1
        accessMutationGeneration &+= 1
    }

    public func updateRelayAccess(
        expectedPairingGen: UInt64,
        expectedAccessGen: UInt64,
        relayOrigin: String,
        deviceToken: String,
        expiresAtString: String
    ) throws -> (pairing: StoredPairing, newAccessGen: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard expectedPairingGen == pairingGeneration,
              expectedAccessGen == accessMutationGeneration else {
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

        try store.save(updated)
        cachedPairing = updated
        lastIdentityToken = deriveIdentityToken(for: updated)
        accessMutationGeneration &+= 1
        return (pairing: updated, newAccessGen: accessMutationGeneration)
    }

    public func clearRelayAccess(
        expectedPairingGen: UInt64,
        expectedAccessGen: UInt64
    ) throws -> (pairing: StoredPairing, newAccessGen: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard expectedPairingGen == pairingGeneration,
              expectedAccessGen == accessMutationGeneration else {
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
        accessMutationGeneration &+= 1
        return (pairing: updated, newAccessGen: accessMutationGeneration)
    }

    public func noteExternalPairingChange(_ pairing: StoredPairing?) {
        lock.lock()
        defer { lock.unlock() }
        cachedPairing = pairing
        lastIdentityToken = pairing.map { self.deriveIdentityToken(for: $0) }
        pairingGeneration &+= 1
        accessMutationGeneration &+= 1
    }

    private func deriveIdentityToken(for pairing: StoredPairing) -> String {
        "\(pairing.instanceID):\(pairing.clientCertPEM.hashValue):\(pairing.pairedAt.timeIntervalSince1970)"
    }
}
