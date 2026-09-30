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
    #if SOLSTONE_BROWSER_INTAKE_PREVIEW
    private var browserCredentialReadable = false

    func matchesBrowserPairing(generation: UInt64, identityDigest: String) -> Bool {
        lock.withLock {
            guard browserCredentialReadable, storedPairingGeneration == generation,
                  let lastIdentityToken else { return false }
            return BrowserOpaqueString.equals(BrowserIntakeStore.identityDigest(of: lastIdentityToken), identityDigest)
        }
    }

    // Serialize the before/write/after lifecycle, including reloads and hook
    // installation. No credential lock spans a callback or async network work.
    // Hooks must not call an identity operation on this store recursively.
    private let browserIdentityLock = NSLock()
    private var beforeIdentityMutation: (@Sendable (String?) throws -> Void)?
    private var afterIdentityMutation: (@Sendable (String?) -> Void)?
    private var afterCredentialLoad: (@Sendable (String?) -> Void)?

    func installBrowserHooks(
        beforeMutation: @escaping @Sendable (String?) throws -> Void,
        afterMutation: @escaping @Sendable (String?) -> Void,
        afterLoad: @escaping @Sendable (String?) -> Void
    ) {
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        beforeIdentityMutation = beforeMutation
        afterIdentityMutation = afterMutation
        afterCredentialLoad = afterLoad
        let identity = lock.withLock { browserCredentialReadable ? lastIdentityToken : nil }
        afterLoad(identity)
    }
    #endif

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
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        #endif
        lock.lock()
        let loaded: StoredPairing?
        do {
            loaded = try store.load()
        } catch {
            #if SOLSTONE_BROWSER_INTAKE_PREVIEW
            browserCredentialReadable = false
            let hook = afterCredentialLoad
            lock.unlock()
            hook?(nil)
            #else
            lock.unlock()
            #endif
            throw error
        }
        let previous = cachedPairing
        cachedPairing = loaded
        let identity = loaded.map { Self.identityToken(for: $0) }
        if identity.map({ Data($0.utf8) }) != lastIdentityToken.map({ Data($0.utf8) }) {
            lastIdentityToken = identity
            storedPairingGeneration &+= 1
            storedAccessGeneration &+= 1
        } else if loaded != previous {
            storedAccessGeneration &+= 1
        }
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserCredentialReadable = true
        let hook = afterCredentialLoad
        lock.unlock()
        hook?(identity)
        #else
        lock.unlock()
        #endif
        return loaded
    }

    public func save(_ pairing: StoredPairing, expectedGeneration: UInt64? = nil) throws {
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        #endif
        let token = Self.identityToken(for: pairing)
        lock.lock()
        var holdsLock = true
        defer {
            if holdsLock { lock.unlock() }
        }
        if let expectedGeneration, expectedGeneration != storedPairingGeneration {
            holdsLock = false
            lock.unlock()
            throw PairingCredentialStoreError.staleGeneration
        }
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserCredentialReadable = false
        let hook = beforeIdentityMutation
        if let hook {
            holdsLock = false
            lock.unlock()
            try hook(token)
            lock.lock()
            holdsLock = true
            if let expectedGeneration, expectedGeneration != storedPairingGeneration {
                holdsLock = false
                lock.unlock()
                throw PairingCredentialStoreError.staleGeneration
            }
        }
        #endif
        try store.save(pairing)
        cachedPairing = pairing
        lastIdentityToken = token
        storedPairingGeneration &+= 1
        storedAccessGeneration &+= 1
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserCredentialReadable = true
        let afterHook = afterIdentityMutation
        #endif
        holdsLock = false
        lock.unlock()
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        afterHook?(token)
        #endif
    }

    public func delete(expectedGeneration: UInt64? = nil, expectedAccessGeneration: UInt64? = nil) throws {
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        #endif
        lock.lock()
        var holdsLock = true
        defer {
            if holdsLock { lock.unlock() }
        }
        if let expectedGeneration, expectedGeneration != storedPairingGeneration {
            holdsLock = false
            lock.unlock()
            throw PairingCredentialStoreError.staleGeneration
        }
        if let expectedAccessGeneration, expectedAccessGeneration != storedAccessGeneration {
            holdsLock = false
            lock.unlock()
            throw PairingCredentialStoreError.staleGeneration
        }
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserCredentialReadable = false
        let hook = beforeIdentityMutation
        if let hook {
            holdsLock = false
            lock.unlock()
            try hook(nil)
            lock.lock()
            holdsLock = true
            if let expectedGeneration, expectedGeneration != storedPairingGeneration {
                holdsLock = false
                lock.unlock()
                throw PairingCredentialStoreError.staleGeneration
            }
            if let expectedAccessGeneration, expectedAccessGeneration != storedAccessGeneration {
                holdsLock = false
                lock.unlock()
                throw PairingCredentialStoreError.staleGeneration
            }
        }
        #endif
        try store.delete()
        cachedPairing = nil
        lastIdentityToken = nil
        storedPairingGeneration &+= 1
        storedAccessGeneration &+= 1
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserCredentialReadable = true
        let afterHook = afterIdentityMutation
        #endif
        holdsLock = false
        lock.unlock()
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        afterHook?(nil)
        #endif
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
        lastIdentityToken = Self.identityToken(for: updated)
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
        lastIdentityToken = Self.identityToken(for: updated)
        storedAccessGeneration &+= 1
        return (pairing: updated, newAccessGen: storedAccessGeneration)
    }

    public func noteExternalPairingChange(_ pairing: StoredPairing?) throws {
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        #endif
        let token = pairing.map { Self.identityToken(for: $0) }
        lock.lock()
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserCredentialReadable = false
        let hook = beforeIdentityMutation
        if let hook {
            lock.unlock()
            try hook(token)
            lock.lock()
        }
        #endif
        cachedPairing = pairing
        lastIdentityToken = token
        storedPairingGeneration &+= 1
        storedAccessGeneration &+= 1
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserCredentialReadable = true
        let afterHook = afterIdentityMutation
        #endif
        lock.unlock()
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        afterHook?(token)
        #endif
    }

    static func identityToken(for pairing: StoredPairing) -> String {
        // SPLKeychainStore persists ISO 8601 dates without fractional seconds.
        // Use that durable precision before and after a credential reload.
        let pairedAt = pairing.pairedAt.timeIntervalSince1970.rounded(.down)
        return [pairing.instanceID, pairing.clientCertPEM, pairing.clientKeyPEM, pairing.caChainPEM, String(pairedAt)].joined(separator: "\u{0}")
    }
}
