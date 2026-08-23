// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing
@testable import solstone

@Suite("Last successful journal contact store")
struct LastSuccessfulJournalContactStoreTests {
    @Test func userDefaultsStoreReadsWritesAndClearsPayload() throws {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let store = UserDefaultsLastSuccessfulJournalContactStore(defaults: isolated.defaults)
        let payload = LastSuccessfulJournalContactPayload(
            date: Date(timeIntervalSince1970: 123),
            fingerprint: "sha256:test"
        )

        #expect(store.read() == .absent)
        store.write(payload)
        #expect(store.read() == .found(payload))
        store.clear()
        #expect(store.read() == .absent)
    }

    @Test func corruptPayloadReportsCouldNotCheck() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        isolated.defaults.set(Data("not json".utf8), forKey: UserDefaultsLastSuccessfulJournalContactStore.storageKey)
        let store = UserDefaultsLastSuccessfulJournalContactStore(defaults: isolated.defaults)
        let fingerprint = JournalConnectionFingerprint(value: "sha256:test")

        #expect(store.read() == .failed)
        #expect(resolveLastSuccessfulJournalContactOutcome(
            read: store.read(),
            currentFingerprint: fingerprint
        ) == .couldNotCheck)
        #expect(resolveLastSuccessfulJournalContactOutcome(
            read: store.read(),
            currentFingerprint: nil
        ) == .couldNotCheck)
    }

    @Test func absentAndMismatchedPayloadsDoNotFabricateSync() {
        let fingerprint = JournalConnectionFingerprint(value: "sha256:current")
        let stale = LastSuccessfulJournalContactPayload(
            date: Date(timeIntervalSince1970: 123),
            fingerprint: "sha256:old"
        )

        #expect(resolveLastSuccessfulJournalContactOutcome(
            read: .absent,
            currentFingerprint: fingerprint
        ) == .noSyncYet)
        #expect(resolveLastSuccessfulJournalContactOutcome(
            read: .found(stale),
            currentFingerprint: fingerprint
        ) == .noSyncYet)
        #expect(resolveLastSuccessfulJournalContactOutcome(
            read: .absent,
            currentFingerprint: nil
        ) == .notLinked)
    }
}

@Suite("Journal connection fingerprint")
struct JournalConnectionFingerprintTests {
    @Test func directFingerprintUsesURLAndKeyWithoutPersistingRawKey() throws {
        let config = AppConfig(
            serverURL: "https://journal.example",
            serverKey: "secret-key",
            serviceMode: .external
        )

        let first = try #require(journalConnectionFingerprint(
            config: config,
            topology: .remote,
            isTunnelManaged: false,
            tunnelPairing: nil
        ))
        let second = try #require(journalConnectionFingerprint(
            config: config,
            topology: .remote,
            isTunnelManaged: false,
            tunnelPairing: TunnelPairingIdentity(instanceID: "ignored", fingerprint: "ignored")
        ))

        #expect(first == second)
        #expect(!first.value.contains("secret-key"))
        #expect(first.value.hasPrefix("sha256:"))
    }

    @Test func tunnelFingerprintUsesCachedPairingIdentity() throws {
        let config = AppConfig(
            serverURL: "http://127.0.0.1:61234",
            serverKey: "runtime-key",
            serviceMode: .external
        )
        let first = try #require(journalConnectionFingerprint(
            config: config,
            topology: .remote,
            isTunnelManaged: true,
            tunnelPairing: TunnelPairingIdentity(instanceID: "instance-a", fingerprint: "fp-a")
        ))
        let second = try #require(journalConnectionFingerprint(
            config: config,
            topology: .remote,
            isTunnelManaged: true,
            tunnelPairing: TunnelPairingIdentity(instanceID: "instance-b", fingerprint: "fp-a")
        ))

        #expect(first != second)
    }

    @Test func bundledFingerprintIncludesJournalPathSentinel() throws {
        let withoutPath = try #require(journalConnectionFingerprint(
            config: AppConfig(serviceMode: .bundled),
            topology: .local,
            isTunnelManaged: false,
            tunnelPairing: nil
        ))
        let withPath = try #require(journalConnectionFingerprint(
            config: AppConfig(serviceMode: .bundled, journalPath: "/Users/me/Journal"),
            topology: .local,
            isTunnelManaged: false,
            tunnelPairing: nil
        ))

        #expect(withoutPath != withPath)
        #expect(isJournalConnectionFingerprintValue(withoutPath.value))
        #expect(isJournalConnectionFingerprintValue(withPath.value))
    }

    @Test func fingerprintPredicateAcceptsMintedValuesAndRejectsNoncanonical() throws {
        let minted = try #require(journalConnectionFingerprint(
            config: AppConfig(serverURL: "https://journal.example", serverKey: "secret", serviceMode: .external),
            topology: .remote,
            isTunnelManaged: false,
            tunnelPairing: nil
        ))
        #expect(isJournalConnectionFingerprintValue(minted.value))
        #expect(!isJournalConnectionFingerprintValue("sha256:test"))
        #expect(!isJournalConnectionFingerprintValue("sha256:" + String(repeating: "A", count: 64)))
        #expect(!isJournalConnectionFingerprintValue("sha256:" + String(repeating: "a", count: 63)))
        #expect(!isJournalConnectionFingerprintValue(String(repeating: "a", count: 64)))
    }
}
