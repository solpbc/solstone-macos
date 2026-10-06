// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SPLTunnel
import Testing
@testable import solstone

private final class BrowserPairingMemoryStore: PairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: StoredPairing?
    private var carriedPairingRecord = CarriedPairingRecord.empty

    init(_ pairing: StoredPairing? = nil) { self.pairing = pairing }
    func save(_ pairing: StoredPairing) throws {
        lock.withLock {
            self.pairing = pairing
            let marker = carriedPairingRecord.localMarker ?? UUID().uuidString
            let revision = PairingCredentialRevision(from: pairing)
            carriedPairingRecord.localMarker = marker
            carriedPairingRecord.completedPortableBaseline = CarriedPairingBaseline(
                journalIdentity: journalMarkConfirmationIdentity(for: pairing),
                fingerprint: revision.fingerprint,
                credentialRevision: revision.revision,
                marker: marker
            )
        }
    }
    func load() throws -> StoredPairing? { lock.withLock { pairing } }
    func delete() throws { lock.withLock { pairing = nil } }
    func loadCarriedPairingRecord() throws -> CarriedPairingRecord { lock.withLock { carriedPairingRecord } }
    func saveCarriedPairingRecord(_ record: CarriedPairingRecord) throws { lock.withLock { carriedPairingRecord = record } }
}

@Suite("BrowserPairingPersistence", .serialized)
struct BrowserPairingPersistenceTests {
    @MainActor @Test func pairingChangesAndReopenKeepPendingPeriodBytes() async throws {
        func pairing(_ instanceID: String) -> StoredPairing {
            StoredPairing(
                instanceID: instanceID,
                homeLabel: "test-home",
                relayEndpoint: "",
                fingerprint: "fixture-fingerprint",
                clientCertPEM: "fixture-certificate-\(instanceID)",
                clientKeyPEM: "fixture-key-\(instanceID)",
                caChainPEM: "fixture-ca",
                relayEnrollment: .unavailable,
                localEndpoints: [],
                pairedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        }
        let first = pairing("browser-persistence-a")
        let credentials = PairingCredentialStore(store: BrowserPairingMemoryStore())
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let projection = try BrowserContractProjection(rootURL: repo.appendingPathComponent("vendor"))
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

        try credentials.save(first)
        let firstGeneration = try #require(owner.store.getDestinationGeneration())
        let batchID = "31313131313131313131313131313131"
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let payload = try JSONSerialization.data(withJSONObject: [
            "type": "batch", "destination_generation": firstGeneration,
            "inst": "instance-one", "batch_id": batchID, "queued_at_ms": now,
            "records": [["t": "segment_start", "ts": now, "ctx": "context-one",
                         "blocks": [["id": "block-one", "text": "held page"]]]]
        ] as [String: Any])
        guard case .message(let replyBytes) = await owner.accept(bytes: payload, direction: "extension_to_host") else {
            Issue.record("paired browser batch should be admitted")
            return
        }
        let reply = try #require(JSONSerialization.jsonObject(with: replyBytes) as? [String: Any])
        let periodID = try #require(reply["period_id"] as? String)
        let payloadURL = owner.store.periodFileURL(for: periodID)
        let originalBytes = try Data(contentsOf: payloadURL)
        #expect(!originalBytes.isEmpty)

        let replacement = pairing("browser-persistence-b")
        try credentials.save(replacement)
        let secondGeneration = try #require(owner.store.getDestinationGeneration())
        #expect(secondGeneration != firstGeneration)
        #expect(owner.store.getOpenPeriodId() == periodID)
        #expect(try Data(contentsOf: payloadURL) == originalBytes)

        try credentials.delete()
        #expect(owner.store.getDestinationGeneration() == nil)
        #expect(owner.store.getOpenPeriodId() == periodID)
        #expect(try Data(contentsOf: payloadURL) == originalBytes)
        owner.stop()

        let reopened = try BrowserIntakeStore(rootURL: root, projection: projection)
        #expect(reopened.getPeriod(periodId: periodID)?.periodId == periodID)
        #expect(try Data(contentsOf: reopened.periodFileURL(for: periodID)) == originalBytes)
        #expect(reopened.getAllFinalizedPeriods().contains { $0.periodId == periodID })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("retired").path))
    }
}

#endif
