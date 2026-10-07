// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

public enum PairingCredentialStoreError: Error, Equatable, Sendable {
    case staleGeneration
    case noPairingFound
    case credentialCleanupPending
    case underlying(String)
}

public protocol PairingStoring: Sendable {
    func load() throws -> StoredPairing?
    func save(_ pairing: StoredPairing) throws
    func delete() throws
    func loadCarriedPairingRecord() throws -> CarriedPairingRecord
    func saveCarriedPairingRecord(_ record: CarriedPairingRecord) throws
}

/// Memory-backed credential storage for snapshot and preview compositions.
/// Those never read or write a real keychain; a held pairing reads as an
/// already-adopted baseline on this device, the state a real store reaches
/// after a verified write.
final class InMemoryPairingStore: PairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: StoredPairing?
    private var record = CarriedPairingRecord.empty

    init(pairing: StoredPairing? = nil) {
        self.pairing = pairing
        if let pairing { adopt(pairing) }
    }

    func load() throws -> StoredPairing? {
        lock.withLock { pairing }
    }

    func save(_ pairing: StoredPairing) throws {
        lock.withLock {
            self.pairing = pairing
            adopt(pairing)
        }
    }

    func delete() throws {
        lock.withLock { pairing = nil }
    }

    func loadCarriedPairingRecord() throws -> CarriedPairingRecord {
        lock.withLock { record }
    }

    func saveCarriedPairingRecord(_ record: CarriedPairingRecord) throws {
        lock.withLock { self.record = record }
    }

    private func adopt(_ pairing: StoredPairing) {
        let marker = record.localMarker ?? UUID().uuidString
        let revision = PairingCredentialRevision(from: pairing)
        record.localMarker = marker
        record.completedPortableBaseline = CarriedPairingBaseline(
            journalIdentity: journalMarkConfirmationIdentity(for: pairing),
            fingerprint: revision.fingerprint,
            credentialRevision: revision.revision,
            marker: marker
        )
    }
}

public final class PairingCredentialStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let store: any PairingStoring
    private var storedPairingGeneration: UInt64 = 1
    private var storedAccessGeneration: UInt64 = 1
    private var cachedPairing: StoredPairing?
    private var lastIdentityToken: String?
    private var migrationRecordCache: CarriedPairingRecord?
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
    private let browserIdentityLock = NSRecursiveLock()
    private var browserMutationLock: NSLock?
    private var beforeIdentityMutation: (@Sendable (String?) throws -> Void)?
    private var afterIdentityMutation: (@Sendable (String?) -> Void)?
    private var afterCredentialLoad: (@Sendable (String?) -> Void)?

    func installBrowserHooks(
        mutationLock: NSLock? = nil,
        beforeMutation: @escaping @Sendable (String?) throws -> Void,
        afterMutation: @escaping @Sendable (String?) -> Void,
        afterLoad: @escaping @Sendable (String?) -> Void
    ) {
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        browserMutationLock = mutationLock
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

    func carriedPairingRecord() throws -> CarriedPairingRecord {
        lock.lock()
        defer { lock.unlock() }
        if let migrationRecordCache { return migrationRecordCache }
        let record = try store.loadCarriedPairingRecord()
        migrationRecordCache = record
        return record
    }

    func saveCarriedPairingRecord(_ record: CarriedPairingRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try store.saveCarriedPairingRecord(record)
            migrationRecordCache = record
        } catch {
            migrationRecordCache = nil
            throw error
        }
    }

    func saveCarriedPairingRecord(
        _ record: CarriedPairingRecord,
        expected: CarriedPairingRecord,
        whilePairing expectedPairing: PairingCredentialRevision
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let pairing = try load(), PairingCredentialRevision(from: pairing) == expectedPairing else {
            throw PairingCredentialStoreError.staleGeneration
        }
        let durableRecord = try store.loadCarriedPairingRecord()
        migrationRecordCache = durableRecord
        guard durableRecord == expected else { throw PairingCredentialStoreError.staleGeneration }
        try store.saveCarriedPairingRecord(record)
        migrationRecordCache = record
    }

    func save(
        _ pairing: StoredPairing,
        replacing candidate: CarriedPairingCandidate,
        expectedRecord: CarriedPairingRecord
    ) throws {
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        #endif
        lock.lock()
        defer { lock.unlock() }
        guard let current = try load(),
              PairingCredentialRevision(from: current).fingerprint == candidate.previousFingerprint,
              PairingCredentialRevision(from: current).revision == candidate.previousRevision,
              current.instanceID == candidate.previousInstanceID else {
            throw PairingCredentialStoreError.staleGeneration
        }
        let durableRecord = try store.loadCarriedPairingRecord()
        migrationRecordCache = durableRecord
        guard durableRecord == expectedRecord,
              durableRecord.invalidation == nil,
              durableRecord.candidate?.operationID == candidate.operationID,
              durableRecord.candidate?.rekeyFingerprint == pairing.fingerprint else {
            throw PairingCredentialStoreError.staleGeneration
        }
        try save(pairing)
    }

    func admission(for pairing: StoredPairing?) -> CarriedPairingAdmission {
        lock.lock()
        defer { lock.unlock() }
        do {
            let record = try carriedPairingRecord()
            if record.invalidation != nil { return .blocked }
            if let candidate = record.candidate {
                guard let pairing else { return .blocked }
                let current = PairingCredentialRevision(from: pairing)
                if candidate.rekeyFingerprint == current.fingerprint
                    || (candidate.previousFingerprint == current.fingerprint
                        && candidate.previousRevision == current.revision
                        && candidate.previousInstanceID == pairing.instanceID) {
                    return .migrationRequired
                }
                if let baseline = record.completedPortableBaseline,
                   !SPLPairingKeychain.localMarkerMatches(record, baseline: baseline) {
                    return .migrationRequired
                }
                return .blocked
            }
            if let baseline = record.completedPortableBaseline {
                guard let pairing else { return .absent }
                guard SPLPairingKeychain.localMarkerMatches(record, baseline: baseline),
                      baseline.fingerprint == pairing.fingerprint,
                      baseline.journalIdentity == journalMarkConfirmationIdentity(for: pairing),
                      baseline.credentialRevision == PairingCredentialRevision(from: pairing).revision,
                      !baseline.sourceProvenance.isEmpty,
                      baseline.destinationProvenance == SPLPairingKeychain.destinationProvenance else {
                    return .migrationRequired
                }
                return .ready
            }
            if record.initialMovePrepared { return .migrationRequired }
            if let preparedFingerprint = record.preparedCredentialFingerprint {
                guard let pairing,
                      preparedFingerprint == pairing.fingerprint,
                      record.preparedCredentialRevision == PairingCredentialRevision(from: pairing).revision,
                      record.preparedJournalIdentity == journalMarkConfirmationIdentity(for: pairing) else {
                    return pairing == nil ? .absent : .blocked
                }
                return .migrationRequired
            }
            guard record.localMarker == nil else { return .blocked }
            return pairing == nil ? .absent : .blocked
        } catch {
            return .blocked
        }
    }

    func ordinarySyncRevision(for identity: TunnelPairingIdentity?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let identity, let pairing = try? load(),
              pairing.instanceID == identity.instanceID,
              pairing.fingerprint == identity.fingerprint,
              admission(for: pairing) == .ready else { return nil }
        return PairingCredentialRevision(from: pairing).revision
    }

    func ordinarySyncIsCurrent(_ context: JournalUploadContext) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let expectedRevision = context.credentialRevision,
              let pairing = try? load(),
              pairing.instanceID == context.pairing.instanceID,
              pairing.fingerprint == context.pairing.fingerprint,
              PairingCredentialRevision(from: pairing).revision == expectedRevision,
              admission(for: pairing) == .ready else { return false }
        return true
    }

    func markAnswerIsCurrent(_ expectedRevision: PairingCredentialRevision) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let pairing = try? load(),
              PairingCredentialRevision(from: pairing) == expectedRevision,
              admission(for: pairing) == .ready else { return false }
        return true
    }

    /// Linearizes a synchronous custody write/removal against durable invalidation.
    /// The operation must not call back into this store or suspend.
    func withOrdinarySyncAdmission<T>(
        _ context: JournalUploadContext,
        operation: () throws -> T
    ) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let expectedRevision = context.credentialRevision,
              let pairing = try? load(),
              pairing.instanceID == context.pairing.instanceID,
              pairing.fingerprint == context.pairing.fingerprint,
              PairingCredentialRevision(from: pairing).revision == expectedRevision,
              admission(for: pairing) == .ready else { return nil }
        return try operation()
    }

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    /// Linearizes browser custody release against durable invalidation. The
    /// route generation and identity digest bind the commit to the connection
    /// that obtained the listing; the operation must be synchronous.
    func withOrdinaryBrowserAdmission<T>(
        generation: UInt64,
        identityDigest: String,
        operation: () throws -> T
    ) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard browserCredentialReadable,
              storedPairingGeneration == generation,
              let identity = lastIdentityToken,
              BrowserOpaqueString.equals(BrowserIntakeStore.identityDigest(of: identity), identityDigest),
              let pairing = cachedPairing,
              admission(for: pairing) == .ready else { return nil }
        return try operation()
    }
#endif

    func owns(_ fingerprint: PairingCredentialRevision, operationID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let pairing = try? load(), let record = try? carriedPairingRecord() else { return false }
        let current = PairingCredentialRevision(from: pairing)
        guard current == fingerprint else { return false }
        if let invalidation = record.invalidation {
            return invalidation.operationID == operationID
                && invalidation.fingerprint == fingerprint.fingerprint
                && invalidation.revision == fingerprint.revision
        }
        if let candidate = record.candidate {
            return candidate.operationID == operationID
                && candidate.previousFingerprint == fingerprint.fingerprint
                && candidate.previousRevision == fingerprint.revision
        }
        return false
    }

    func beginInvalidation(for pairing: StoredPairing, operationID: String = UUID().uuidString) throws -> CarriedPairingInvalidation {
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        #endif
        lock.lock()
        defer { lock.unlock() }
        let identity = PairingCredentialRevision(from: pairing)
        guard let current = try load(), PairingCredentialRevision(from: current) == identity else {
            throw PairingCredentialStoreError.staleGeneration
        }
        var record = try carriedPairingRecord()
        if let existing = record.invalidation {
            guard existing.fingerprint == identity.fingerprint,
                  existing.revision == identity.revision,
                  existing.journalIdentity == journalMarkConfirmationIdentity(for: pairing) else {
                throw PairingCredentialStoreError.staleGeneration
            }
            return existing
        }
        let invalidation = CarriedPairingInvalidation(
            operationID: operationID,
            fingerprint: identity.fingerprint,
            journalIdentity: journalMarkConfirmationIdentity(for: pairing),
            revision: identity.revision,
            remoteRetirementAttempted: false,
            remoteRetirementConfirmed: false,
            credentialCleanupPending: true
        )
        record.invalidation = invalidation
        try saveCarriedPairingRecord(record)
        return invalidation
    }

    func updateInvalidation(_ invalidation: CarriedPairingInvalidation) throws {
        lock.lock()
        defer { lock.unlock() }
        var record = try carriedPairingRecord()
        guard record.invalidation?.operationID == invalidation.operationID,
              record.invalidation?.fingerprint == invalidation.fingerprint,
              record.invalidation?.revision == invalidation.revision,
              record.invalidation?.journalIdentity == invalidation.journalIdentity else {
            throw PairingCredentialStoreError.staleGeneration
        }
        record.invalidation = invalidation
        try saveCarriedPairingRecord(record)
    }

    func updateInvalidation(
        _ invalidation: CarriedPairingInvalidation,
        whilePairing pairing: StoredPairing
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let current = try load(),
              PairingCredentialRevision(from: current) == PairingCredentialRevision(from: pairing) else {
            throw PairingCredentialStoreError.staleGeneration
        }
        var record = try carriedPairingRecord()
        guard record.invalidation?.operationID == invalidation.operationID,
              record.invalidation?.fingerprint == invalidation.fingerprint,
              record.invalidation?.revision == invalidation.revision,
              record.invalidation?.journalIdentity == invalidation.journalIdentity else {
            throw PairingCredentialStoreError.staleGeneration
        }
        record.invalidation = invalidation
        try saveCarriedPairingRecord(record)
    }

    func clearInvalidation(
        operationID: String,
        fingerprint: String,
        revision: String,
        expectedCurrentPairing: PairingCredentialRevision?
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let current = try load()
        let currentRevision = current.map { PairingCredentialRevision(from: $0) }
        guard currentRevision == expectedCurrentPairing else {
            throw PairingCredentialStoreError.staleGeneration
        }
        var record = try carriedPairingRecord()
        guard record.invalidation?.operationID == operationID,
              record.invalidation?.fingerprint == fingerprint,
              record.invalidation?.revision == revision else {
            throw PairingCredentialStoreError.staleGeneration
        }
        record.invalidation = nil
        if record.candidate?.previousFingerprint == fingerprint,
           record.candidate?.previousRevision == revision {
            record.candidate = nil
        }
        if record.decision?.credentialFingerprint == fingerprint,
           record.decision?.credentialRevision == revision {
            record.decision = nil
        }
        try saveCarriedPairingRecord(record)
    }

    public func load() throws -> StoredPairing? {
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        #endif
        lock.lock()
        let loaded: StoredPairing?
        let durableMigrationRecord: CarriedPairingRecord
        do {
            loaded = try store.load()
            durableMigrationRecord = try store.loadCarriedPairingRecord()
        } catch {
            migrationRecordCache = nil
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
        // The backend may complete an initial move while loading the credential.
        // Refresh the serialized state from that same backend before callers
        // evaluate admission for the returned pairing.
        migrationRecordCache = durableMigrationRecord
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
        browserMutationLock?.lock()
        defer { browserMutationLock?.unlock() }
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
        let wasBrowserCredentialReadable = browserCredentialReadable
        browserCredentialReadable = false
        let hook = beforeIdentityMutation
        if let hook {
            holdsLock = false
            lock.unlock()
            do { try hook(token) }
            catch {
                lock.withLock { browserCredentialReadable = wasBrowserCredentialReadable }
                throw error
            }
            lock.lock()
            holdsLock = true
            if let expectedGeneration, expectedGeneration != storedPairingGeneration {
                holdsLock = false
                lock.unlock()
                throw PairingCredentialStoreError.staleGeneration
            }
        }
        #endif
        do {
            try store.save(pairing)
        } catch {
            #if SOLSTONE_BROWSER_INTAKE_PREVIEW
            browserCredentialReadable = wasBrowserCredentialReadable
            let afterHook = afterIdentityMutation
            let previousIdentity = lastIdentityToken
            holdsLock = false
            lock.unlock()
            afterHook?(previousIdentity)
            #endif
            throw error
        }
        migrationRecordCache = try? store.loadCarriedPairingRecord()
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

    func save(_ pairing: StoredPairing, after invalidation: CarriedPairingInvalidation) throws {
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        #endif
        lock.lock()
        defer { lock.unlock() }
        guard let current = try load(),
              PairingCredentialRevision(from: current).fingerprint == invalidation.fingerprint,
              PairingCredentialRevision(from: current).revision == invalidation.revision,
              let record = try? carriedPairingRecord(),
              record.invalidation?.operationID == invalidation.operationID,
              record.invalidation?.fingerprint == invalidation.fingerprint,
              record.invalidation?.revision == invalidation.revision,
              record.invalidation?.journalIdentity == invalidation.journalIdentity,
              record.invalidation?.remoteRetirementAttempted == true else {
            throw PairingCredentialStoreError.staleGeneration
        }
        try save(pairing)
    }

    func delete(after invalidation: CarriedPairingInvalidation) throws {
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        #endif
        lock.lock()
        defer { lock.unlock() }
        guard let current = try load(),
              PairingCredentialRevision(from: current).fingerprint == invalidation.fingerprint,
              PairingCredentialRevision(from: current).revision == invalidation.revision,
              let record = try? carriedPairingRecord(),
              record.invalidation?.operationID == invalidation.operationID,
              record.invalidation?.fingerprint == invalidation.fingerprint,
              record.invalidation?.revision == invalidation.revision,
              record.invalidation?.journalIdentity == invalidation.journalIdentity,
              record.invalidation?.remoteRetirementAttempted == true else {
            throw PairingCredentialStoreError.staleGeneration
        }
        try delete(expectedGeneration: storedPairingGeneration)
        guard try store.load() == nil else { throw PairingCredentialStoreError.staleGeneration }
        let cleanupRecord = try store.loadCarriedPairingRecord()
        migrationRecordCache = cleanupRecord
        guard !cleanupRecord.legacyCleanupPending else {
            throw PairingCredentialStoreError.credentialCleanupPending
        }
    }

    public func delete(expectedGeneration: UInt64? = nil, expectedAccessGeneration: UInt64? = nil) throws {
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIdentityLock.lock()
        defer { browserIdentityLock.unlock() }
        browserMutationLock?.lock()
        defer { browserMutationLock?.unlock() }
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
        let wasBrowserCredentialReadable = browserCredentialReadable
        browserCredentialReadable = false
        let hook = beforeIdentityMutation
        if let hook {
            holdsLock = false
            lock.unlock()
            do { try hook(nil) }
            catch {
                lock.withLock { browserCredentialReadable = wasBrowserCredentialReadable }
                throw error
            }
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
        do {
            try store.delete()
        } catch {
            #if SOLSTONE_BROWSER_INTAKE_PREVIEW
            browserCredentialReadable = wasBrowserCredentialReadable
            let afterHook = afterIdentityMutation
            let previousIdentity = lastIdentityToken
            holdsLock = false
            lock.unlock()
            afterHook?(previousIdentity)
            #endif
            throw error
        }
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
        browserMutationLock?.lock()
        defer { browserMutationLock?.unlock() }
        #endif
        let token = pairing.map { Self.identityToken(for: $0) }
        lock.lock()
        #if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let wasBrowserCredentialReadable = browserCredentialReadable
        browserCredentialReadable = false
        let hook = beforeIdentityMutation
        if let hook {
            lock.unlock()
            do { try hook(token) }
            catch {
                lock.withLock { browserCredentialReadable = wasBrowserCredentialReadable }
                throw error
            }
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
        return ["browser-pairing-v2", journalMarkConfirmationIdentity(for: pairing), pairing.instanceID, pairing.clientCertPEM, pairing.clientKeyPEM, pairing.caChainPEM, String(pairedAt)].joined(separator: "\u{0}")
    }
}
