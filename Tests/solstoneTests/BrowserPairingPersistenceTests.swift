// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SPLTunnel
import Testing
@testable import solstone

private final class SerializedBrowserPairingStore: PairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func save(_ pairing: StoredPairing) throws {
        // Match the released SPLKeychainStore's durable date representation.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(pairing)
        lock.withLock { data = encoded }
    }

    func load() throws -> StoredPairing? {
        guard let data = lock.withLock({ data }) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredPairing.self, from: data)
    }

    func delete() throws {
        lock.withLock { data = nil }
    }
}

@Suite("BrowserPairingPersistence", .serialized)
struct BrowserPairingPersistenceTests {
    @Test(arguments: [0.0, 0.001, 0.987])
    func savedPairingReloadPreservesAdmissionAndExplicitReplacement(fraction: Double) async throws {
        let original = StoredPairing(
            instanceID: "pairing-persistence-journal",
            homeLabel: "test-home",
            relayEndpoint: "",
            fingerprint: "fixture-fingerprint",
            clientCertPEM: "fixture-certificate",
            clientKeyPEM: "fixture-key",
            caChainPEM: "fixture-ca",
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_700_000_100 + fraction)
        )
        let credentials = PairingCredentialStore(store: SerializedBrowserPairingStore())
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let projection = try BrowserContractProjection(rootURL: repository.appendingPathComponent("vendor"))
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("browser-pairing-persistence-\(UUID().uuidString)", isDirectory: true)
        let owner = try BrowserIntakeOwner.start(
            spoolRoot: root,
            projection: projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: nil),
            routeResolver: HomeBaseURLResolver { .held }
        )
        defer { owner.stop(); try? FileManager.default.removeItem(at: root) }
        owner.bindCredentials(credentials)
        await owner.start()

        try credentials.save(original)
        #expect(owner.authority.isAdmissionOpen())
        let generation = try #require(owner.store.getActiveGeneration())
        let period = try #require(owner.store.getOpenPeriodId())
        let persisted = try credentials.load()
        let loaded = try #require(persisted)
        #expect(loaded.pairedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect((loaded.pairedAt == original.pairedAt) == (fraction == 0))
        guard owner.authority.isAdmissionOpen() else {
            Issue.record("saved pairing reload closed batch admission")
            await owner.stopAndDrain()
            return
        }
        #expect(owner.store.getActiveGeneration() == generation)
        #expect(owner.store.getOpenPeriodId() == period)
        let projected = await owner.currentHostProjection()
        #expect(projected.facts.capture == "permitted")
        #expect(projected.facts.destinationGeneration == generation)

        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let batch: [String: Any] = [
            "type": "batch", "destination_generation": generation,
            "inst": "instance-one", "batch_id": "31313131313131313131313131313131",
            "queued_at_ms": now,
            "records": [["t": "segment_start", "ts": now, "ctx": "context-one", "inst": "instance-one",
                         "blocks": [["id": "block-one", "text": "synthetic persistence boundary"]]]]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: batch)
        let result = await owner.accept(bytes: encoded, direction: "extension_to_host")
        guard case .message(let bytes) = result else {
            Issue.record("saved pairing reload closed batch admission")
            await owner.stopAndDrain()
            return
        }
        let reply = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(reply["type"] as? String == "accepted")
        try #require(reply["result"] as? String == "accepted")
        #expect(reply["period_id"] as? String == period)
        let file = owner.store.periodFileURL(for: period)
        let held = try Data(contentsOf: file)
        #expect(!held.isEmpty)

        // An explicit save still retires authority even for identical credentials.
        try credentials.save(original)
        let replacement = try #require(owner.store.getActiveGeneration())
        #expect(replacement != generation)
        #expect(owner.store.getPeriod(periodId: period)?.state == "finalized")
        #expect(try Data(contentsOf: file) == held)
        _ = try credentials.load()
        #expect(owner.authority.isAdmissionOpen())
        #expect(owner.store.getActiveGeneration() == replacement)
        await owner.stopAndDrain()
    }
}

#endif
