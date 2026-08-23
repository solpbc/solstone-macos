// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing
@testable import solstone

@Suite("Last journal delivery store")
struct LastJournalDeliveryStoreTests {
    @Test func resolverTruthTableMirrorsStorageFirstPrecedence() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fingerprint = canonicalDeliveryFingerprint()
        let identified = JournalIdentityRead.identified(fingerprint)
        let matching = LastJournalDeliveryPayload(date: now, fingerprint: fingerprint.value)
        let mismatched = LastJournalDeliveryPayload(
            date: now,
            fingerprint: canonicalDeliveryFingerprint("other").value
        )
        let negative = LastJournalDeliveryPayload(
            date: Date(timeIntervalSince1970: -1),
            fingerprint: fingerprint.value
        )
        let future = LastJournalDeliveryPayload(
            date: Date(timeIntervalSince1970: 1_001),
            fingerprint: fingerprint.value
        )

        // Storage failure is judged before identity.
        for identity in [JournalIdentityRead.absent, .failed, identified] {
            #expect(resolveLastJournalDeliveryOutcome(
                read: .failed,
                identity: identity,
                now: now,
                persistenceFailed: false
            ) == .unavailable)
            #expect(resolveLastJournalDeliveryOutcome(
                read: .found(negative),
                identity: identity,
                now: now,
                persistenceFailed: false
            ) == .unavailable)
            #expect(resolveLastJournalDeliveryOutcome(
                read: .found(future),
                identity: identity,
                now: now,
                persistenceFailed: false
            ) == .unavailable)
        }

        #expect(resolveLastJournalDeliveryOutcome(
            read: .absent,
            identity: .failed,
            now: now,
            persistenceFailed: false
        ) == .unavailable)
        #expect(resolveLastJournalDeliveryOutcome(
            read: .found(matching),
            identity: .failed,
            now: now,
            persistenceFailed: false
        ) == .unavailable)

        #expect(resolveLastJournalDeliveryOutcome(
            read: .absent,
            identity: .absent,
            now: now,
            persistenceFailed: false
        ) == .notLinked)
        #expect(resolveLastJournalDeliveryOutcome(
            read: .found(matching),
            identity: .absent,
            now: now,
            persistenceFailed: false
        ) == .notLinked)

        #expect(resolveLastJournalDeliveryOutcome(
            read: .absent,
            identity: identified,
            now: now,
            persistenceFailed: false
        ) == .noDeliveryYet)
        #expect(resolveLastJournalDeliveryOutcome(
            read: .found(mismatched),
            identity: identified,
            now: now,
            persistenceFailed: false
        ) == .noDeliveryYet)
        #expect(resolveLastJournalDeliveryOutcome(
            read: .found(matching),
            identity: identified,
            now: now,
            persistenceFailed: false
        ) == .delivered(now))

        #expect(resolveLastJournalDeliveryOutcome(
            read: .found(matching),
            identity: identified,
            now: now,
            persistenceFailed: true
        ) == .delivered(now))
        #expect(resolveLastJournalDeliveryOutcome(
            read: .absent,
            identity: identified,
            now: now,
            persistenceFailed: true
        ) == .unavailable)
        #expect(resolveLastJournalDeliveryOutcome(
            read: .found(matching),
            identity: .absent,
            now: now,
            persistenceFailed: true
        ) == .unavailable)
        #expect(resolveLastJournalDeliveryOutcome(
            read: .failed,
            identity: identified,
            now: now,
            persistenceFailed: true
        ) == .unavailable)
    }

    @Test func userDefaultsWriteConfirmsByReadBack() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let store = UserDefaultsLastJournalDeliveryStore(defaults: isolated.defaults)
        let payload = LastJournalDeliveryPayload(
            date: Date(timeIntervalSince1970: 123),
            fingerprint: canonicalDeliveryFingerprint().value
        )

        #expect(store.read() == .absent)
        #expect(store.write(payload) == .confirmed)
        #expect(store.read() == .found(payload))
    }

    @Test func isolatedUserDefaultsRawDataContainsOnlyDateAndFingerprint() throws {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let store = UserDefaultsLastJournalDeliveryStore(defaults: isolated.defaults)
        let payload = LastJournalDeliveryPayload(
            date: Date(timeIntervalSince1970: 123),
            fingerprint: canonicalDeliveryFingerprint().value
        )
        #expect(store.write(payload) == .confirmed)

        let data = try #require(isolated.defaults.data(forKey: UserDefaultsLastJournalDeliveryStore.storageKey))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["date", "fingerprint"])
        #expect(object["fingerprint"] as? String == payload.fingerprint)
        let decoded = try JSONDecoder().decode(LastJournalDeliveryPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test func undecodableAndNoncanonicalFingerprintsReadAsFailed() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        isolated.defaults.set(Data("not json".utf8), forKey: UserDefaultsLastJournalDeliveryStore.storageKey)
        let store = UserDefaultsLastJournalDeliveryStore(defaults: isolated.defaults)
        #expect(store.read() == .failed)

        let noncanonical = LastJournalDeliveryPayload(
            date: Date(timeIntervalSince1970: 123),
            fingerprint: "sha256:test"
        )
        isolated.defaults.set(try! JSONEncoder().encode(noncanonical), forKey: UserDefaultsLastJournalDeliveryStore.storageKey)
        #expect(store.read() == .failed)
    }
}

func canonicalDeliveryFingerprint(_ distinct: String = "a") -> JournalConnectionFingerprint {
    journalConnectionFingerprint(
        config: AppConfig(
            serverURL: "https://\(distinct).example.test",
            serverKey: "key-\(distinct)",
            serviceMode: .external
        ),
        topology: .remote,
        isTunnelManaged: false,
        tunnelPairing: nil
    )!
}
