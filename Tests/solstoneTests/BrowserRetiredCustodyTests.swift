// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SQLite3
import SPLTunnel
import Testing
@testable import solstone

private enum BrowserRetiredTestFailure: Error {
    case injected
}

private final class BrowserRetiredOneShotFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    func take() -> Bool {
        lock.withLock {
            guard available else { return false }
            available = false
            return true
        }
    }
}

private final class BrowserRetiredPublicationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var syncs = 0
    private var publications = 0
    let failAfterRename: Bool
    init(failAfterRename: Bool) { self.failAfterRename = failAfterRename }
    func check(_ point: BrowserIntakeIOPoint) throws {
        let fails = lock.withLock { () -> Bool in
            if point == .retiredDiscardIntent || point == .retiredTransitionIntent {
                armed = true
                publications += 1
                if !failAfterRename { return publications == 2 }
            }
            if armed && point == .sync {
                syncs += 1
                return failAfterRename && syncs >= 2
            }
            return false
        }
        if fails { throw BrowserRetiredTestFailure.injected }
    }
}

private struct BrowserRetiredTestFile: Equatable {
    let path: String
    let data: Data
}

private final class BrowserRetiredTestClock: @unchecked Sendable {
    let date = Date(timeIntervalSince1970: 1_700_000_100)
}

@Suite("BrowserRetiredCustody", .serialized)
struct BrowserRetiredCustodyTests {
    @Test(arguments: [false, true])
    func failedPostRenameIntentSyncPreservesPayloadUntilDurabilityIsEarned(transition: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let injector = BrowserIntakeIOInjector()
        let spool = directory.appendingPathComponent("spool")
        let (store, authority) = try storeAndAuthority(spool, projection: projection, injector: injector)
        let generation = try authority.publishEpoch(identityToken: "publication-proof")
        let period = try acceptedPeriod(authority, bytes: batch(generation: generation, id: 89))
        let payload: URL
        let scope: BrowserRetiredCustodyScope?
        if transition {
            payload = store.periodFileURL(for: period)
            scope = nil
        } else {
            try authority.retireIfTokenChanged(newToken: nil)
            payload = retiredPayload(spool, period)
            guard case .present(let selected) = store.retiredCustodyInventory() else {
                Issue.record("Expected a selected retired payload")
                return
            }
            scope = selected
        }
        let original = try Data(contentsOf: payload)
        let failure = BrowserRetiredPublicationFailure(failAfterRename: true)
        injector.setFailure { try failure.check($0) }
        if transition {
            #expect(throws: BrowserRetiredTestFailure.self) { try authority.retireIfTokenChanged(newToken: nil) }
        } else {
            let result = store.discardRetiredCustodyAndMeasure(try #require(scope))
            #expect(!result.durablyCompleted)
            #expect(result.inventory == .unavailable)
        }
        #expect(store.retiredCustodyInventory() == .unavailable)
        #expect(try Data(contentsOf: payload) == original)
        let marker = transition ? "transition.json" : "discard-intent.json"
        #expect(FileManager.default.fileExists(atPath: spool.appendingPathComponent("retired/\(marker)").path))
        injector.setFailure(nil)
        let recovered = store.retiredCustodyInventory()
        if transition {
            guard case .present = recovered else { Issue.record("Durable transition recovery should preserve inventory"); return }
            #expect(try Data(contentsOf: retiredPayload(spool, period)) == original)
        } else {
            #expect(recovered == .empty)
            #expect(!FileManager.default.fileExists(atPath: payload.path))
        }
    }

    @Test func thrownCompletionPublicationRecoveryReturnsTheExactDurableProof() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let injector = BrowserIntakeIOInjector()
        let (store, authority) = try storeAndAuthority(directory.appendingPathComponent("spool"), projection: projection, injector: injector)
        let generation = try authority.publishEpoch(identityToken: "completion-proof")
        _ = try acceptedPeriod(authority, bytes: batch(generation: generation, id: 90))
        try authority.retireIfTokenChanged(newToken: nil)
        guard case .present(let scope) = store.retiredCustodyInventory() else {
            Issue.record("Expected a selected retired payload")
            return
        }
        let failure = BrowserRetiredPublicationFailure(failAfterRename: false)
        injector.setFailure { try failure.check($0) }
        let result = store.discardRetiredCustodyAndMeasure(scope)
        #expect(result.durablyCompleted)
        #expect(result.inventory == .empty)
    }

    @Test func suspendedListingFailureCannotSetSuccessorFactsButCurrentFailureCan() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let (store, authority) = try storeAndAuthority(directory.appendingPathComponent("spool"), projection: projection)
        func finalized(_ generation: String, _ id: Int) throws -> String {
            let period = try acceptedPeriod(authority, bytes: batch(generation: generation, id: id))
            try store.finalizePeriod(periodId: period, reason: "listing-fixture",
                civilDate: Date(timeIntervalSince1970: 1_700_000_100), timeZone: TimeZone(secondsFromGMT: 0)!, openReplacement: false)
            let row = try #require(store.getPeriod(periodId: period))
            try store.persistDeliveryBinding(.init(generation: generation, periodId: period,
                sha256: try #require(row.fileSha256), size: UInt64(row.committedLength), metadata: nil,
                requestedDay: try #require(row.requestedDay), requestedSegment: try #require(row.requestedSegment), canonicalKey: nil, status: .ok))
            return period
        }
        func route(_ identity: String, _ incarnation: UInt64) -> BrowserIntakeRouteState {
            let state = BrowserIntakeRouteState()
            _ = state.update(.init(serverURL: "http://127.0.0.1", identityDigest: BrowserIntakeStore.identityDigest(of: identity),
                pairingGeneration: 1, transportIncarnation: incarnation, credentialIsCurrent: { true }))
            return state
        }
        let a = try authority.publishEpoch(identityToken: "listing-a")
        _ = try finalized(a, 86)
        let transport = SuspendedRetiredTransport(suspendListing: true)
        let plannerA = BrowserUploadPlanner(store: store, gate: BrowserUploadGate(store: store), client: transport,
            nowMs: { 1_700_000_100_000 }, routeState: route("listing-a", 1))
        let oldTask = Task { await plannerA.planAndUpload() }
        defer { transport.resume() }
        try #require(await transport.waitUntilSuspended())
        let b = try authority.publishEpoch(identityToken: "listing-b")
        let bPeriod = try acceptedPeriod(authority, bytes: batch(generation: b, id: 87))
        let bytesB = try Data(contentsOf: store.periodFileURL(for: bPeriod))
        let before = authority.status()
        transport.resume()
        await oldTask.value
        let after = authority.status()
        #expect(after["delivery"] as? String == before["delivery"] as? String)
        #expect(after["failure"] == nil)
        #expect(after["destination_generation"] as? String == b)
        #expect(!store.storeIsFailed())
        #expect(try Data(contentsOf: store.periodFileURL(for: bPeriod)) == bytesB)
        _ = try finalized(b, 88)
        let plannerB = BrowserUploadPlanner(store: store, gate: BrowserUploadGate(store: store), client: transport,
            nowMs: { 1_700_000_100_000 }, routeState: route("listing-b", 2))
        await plannerB.planAndUpload()
        #expect(authority.status()["delivery"] as? String == "failed")
        #expect(authority.status()["failure"] as? String == "relay_unavailable")
    }

    @Test func legacySpoolWithoutAdmissionJournalIdentityFailsClosedWithoutChangingPayload() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let (store, authority) = try storeAndAuthority(directory, projection: projection)
        let generation = try authority.publishEpoch(identityToken: "old-preview-spool")
        let period = try acceptedPeriod(authority, bytes: batch(generation: generation, id: 81))
        let payload = store.periodFileURL(for: period)
        let held = try Data(contentsOf: payload)
        var database: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("intake.sqlite").path, &database) == SQLITE_OK)
        do {
            defer { sqlite3_close(database) }
            try #require(sqlite3_exec(database, "ALTER TABLE epoch DROP COLUMN journal_identity;", nil, nil, nil) == SQLITE_OK)
        }
        #expect(throws: (any Error).self) {
            _ = try BrowserIntakeStore(rootURL: directory, projection: projection)
        }
        #expect(try Data(contentsOf: payload) == held)
    }

    @Test func sameJournalReplacementKeepsGenerationButChangedCAOrInstanceRetiresIt() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        func credential(instance: String = "journal-a", ca: String = "ca-a", key: String) -> String {
            PairingCredentialStore.identityToken(for: StoredPairing(
                instanceID: instance, homeLabel: "fixture", relayEndpoint: "", fingerprint: "fixture",
                clientCertPEM: "certificate-" + key, clientKeyPEM: key, caChainPEM: ca,
                relayEnrollment: .unavailable, localEndpoints: [], pairedAt: Date(timeIntervalSince1970: 1_700_000_100)))
        }
        let (store, authority) = try storeAndAuthority(directory, projection: projection)
        let tokenA = credential(key: "key-one")
        let tokenA2 = credential(key: "key-two")
        let generation = try authority.publishEpoch(identityToken: tokenA)
        let period = try acceptedPeriod(authority, bytes: batch(generation: generation, id: 82))
        let held = try Data(contentsOf: store.periodFileURL(for: period))
        let firstPermit = try #require(store.currentDeliveryPermit())
        try authority.reconcileIdentity(tokenA2, mode: .replace)
        #expect(store.getActiveGeneration() == generation)
        #expect(store.currentDeliveryPermit() == nil)
        #expect(try authority.publishEpoch(identityToken: tokenA2) == generation)
        let nextPermit = try #require(store.currentDeliveryPermit())
        #expect(firstPermit.identityToken != nextPermit.identityToken)
        #expect(store.retiredCustodyInventory() == .empty)
        #expect(try Data(contentsOf: store.periodFileURL(for: period)) == held)
        let reopened = try BrowserIntakeStore(rootURL: directory, projection: projection)
        #expect(reopened.matchesActiveJournal(identityToken: tokenA2))
        #expect(!reopened.matchesActiveJournal(identityToken: credential(ca: "ca-b", key: "key-three")))
        #expect(!reopened.matchesActiveJournal(identityToken: credential(instance: "journal-b", key: "key-three")))
        let tokenB = credential(ca: "ca-b", key: "key-three")
        try authority.reconcileIdentity(tokenB, mode: .replace)
        let generationB = try authority.publishEpoch(identityToken: tokenB)
        #expect(generationB != generation)
        #expect(try Data(contentsOf: retiredPayload(directory, period)) == held)
        #expect(store.getPeriod(periodId: period) == nil)
        authority.reopenAdmission()
        #expect(try authority.accept(bytes: batch(generation: generationB, id: 83), direction: "extension_to_host")["result"] as? String == "accepted")
        let tokenC = credential(instance: "journal-c", ca: "ca-c", key: "key-four")
        try authority.reconcileIdentity(tokenC, mode: .replace)
        #expect(try authority.publishEpoch(identityToken: tokenC) != generationB)
        var catalog: OpaquePointer?
        try #require(sqlite3_open_v2(directory.appendingPathComponent("retired/catalog.sqlite").path, &catalog, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(catalog) }
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(catalog, "SELECT journal_identity FROM epoch WHERE destination_generation = ?", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        generation.withCString { value in _ = sqlite3_bind_text(statement, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        let retained = try #require(sqlite3_column_text(statement, 0))
        #expect(String(cString: retained) == tokenA.components(separatedBy: "\u{0}")[1])
        #expect(try Data(contentsOf: retiredPayload(directory, period)) == held)
    }

    @Test func recoveredDiscardCompletionHasProofForTheConfirmedSelection() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let injector = BrowserIntakeIOInjector()
        let (store, authority) = try storeAndAuthority(directory.appendingPathComponent("spool"), projection: projection, injector: injector)
        let generation = try authority.publishEpoch(identityToken: "discard-recovery")
        _ = try acceptedPeriod(authority, bytes: batch(generation: generation, id: 85))
        try authority.retireIfTokenChanged(newToken: nil)
        guard case .present(let scope) = store.retiredCustodyInventory() else {
            Issue.record("Expected a concrete discard selection")
            return
        }
        let failure = BrowserRetiredOneShotFailure()
        injector.setFailure { point in
            if point == .retiredDirectorySync && failure.take() { throw BrowserRetiredTestFailure.injected }
        }
        let result = store.discardRetiredCustodyAndMeasure(scope)
        #expect(result.durablyCompleted)
        #expect(result.inventory == .empty)
        let unrelated = BrowserRetiredCustodyScope(identities: [.init(generation: UUID().uuidString,
            periodId: UUID().uuidString, committedLength: 1)])
        #expect(!store.discardRetiredCustodyAndMeasure(unrelated).durablyCompleted)
        #expect(!store.discardRetiredCustodyAndMeasure(.init(identities: [])).durablyCompleted)
    }
    private var vendorURL: URL {
        let file = URL(fileURLWithPath: #filePath)
        return file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vendor")
    }

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/var/tmp/solstone-retired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func copiedProjection(in directory: URL, spoolBytes: Int) throws -> BrowserContractProjection {
        let copy = directory.appendingPathComponent("vendor", isDirectory: true)
        try FileManager.default.copyItem(at: vendorURL, to: copy)
        let authorityURL = copy.appendingPathComponent("contracts/native-browser/authority.json")
        var authority = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: authorityURL)) as? [String: Any])
        var policy = try #require(authority["policy"] as? [String: Any])
        policy["spool_bytes"] = spoolBytes
        authority["policy"] = policy
        try JSONSerialization.data(withJSONObject: authority, options: [.sortedKeys]).write(to: authorityURL)
        return try BrowserContractProjection(rootURL: copy)
    }

    private func batch(generation: String, id: Int, text: String = "retired marker") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "batch",
            "destination_generation": generation,
            "inst": "retired-test-inst",
            "batch_id": String(format: "%032x", id),
            "queued_at_ms": 1_700_000_100_000,
            "records": [[
                "t": "segment_start",
                "ts": 1_700_000_100_000,
                "ctx": "retired-context-\(id)",
                "blocks": [["id": "block-\(id)", "text": text]]
            ]]
        ])
    }

    private func largeBatch(generation: String, marker: String) throws -> Data {
        let text = String(repeating: marker, count: 2_000)
        let blocks = (0..<1_500).map { ["id": "\(marker)-\($0)", "text": text] }
        return try JSONSerialization.data(withJSONObject: [
            "type": "batch",
            "destination_generation": generation,
            "inst": "retired-large-inst",
            "batch_id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "queued_at_ms": 1_700_000_100_000,
            "records": [[
                "t": "segment_start", "ts": 1_700_000_100_000,
                "ctx": "large-context-\(marker)", "blocks": blocks
            ]]
        ])
    }

    private func mediumBatch(generation: String, id: Int, marker: String, blockCount: Int) throws -> Data {
        let text = String(repeating: marker, count: 2_000)
        let blocks = (0..<blockCount).map { ["id": "\(marker)-\($0)", "text": text] }
        return try JSONSerialization.data(withJSONObject: [
            "type": "batch",
            "destination_generation": generation,
            "inst": "retired-test-inst",
            "batch_id": String(format: "%032x", id),
            "queued_at_ms": 1_700_000_100_000,
            "records": [[
                "t": "segment_start", "ts": 1_700_000_100_000,
                "ctx": "medium-context-\(id)", "blocks": blocks
            ]]
        ])
    }

    private func acceptedPeriod(_ authority: BrowserIntakeAuthority, bytes: Data) throws -> String {
        let reply = try authority.accept(bytes: bytes, direction: "extension_to_host")
        #expect(reply["result"] as? String == "accepted")
        return try #require(reply["period_id"] as? String)
    }

    private func retiredPayload(_ root: URL, _ periodId: String) -> URL {
        root.appendingPathComponent("retired/periods/\(periodId)/browser_pages.jsonl")
    }

    private func snapshotTree(_ root: URL) throws -> [BrowserRetiredTestFile] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [BrowserRetiredTestFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                result.append(BrowserRetiredTestFile(path: url.path.replacingOccurrences(of: root.path + "/", with: ""),
                    data: try Data(contentsOf: url)))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func storeAndAuthority(_ root: URL, projection: BrowserContractProjection,
                                   injector: BrowserIntakeIOInjector = BrowserIntakeIOInjector()) throws
        -> (BrowserIntakeStore, BrowserIntakeAuthority) {
        let store = try BrowserIntakeStore(rootURL: root, projection: projection, ioInjector: injector,
            ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 1) }, metadataPageLimit: 256)
        let clock = BrowserRetiredTestClock()
        return (store, BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.date },
            timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    @Test(arguments: [BrowserIntakeIOPoint.read, .step])
    func pendingMeasurementFailureIsUnknown(point: BrowserIntakeIOPoint) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let injector = BrowserIntakeIOInjector()
        let (store, authority) = try storeAndAuthority(directory.appendingPathComponent("spool"), projection: projection, injector: injector)
        let generation = try authority.publishEpoch(identityToken: "pending-unknown")
        let period = try acceptedPeriod(authority, bytes: batch(generation: generation, id: 201))
        #expect(try #require(store.activePending()).identities.map(\.periodId) == [period])
        injector.setFailure { if $0 == point { throw BrowserRetiredTestFailure.injected } }
        #expect(store.activePending() == nil)
        injector.setFailure(nil)
        #expect(store.activePending() == nil)
        #expect(store.storeIsFailed())
    }

    @Test func pendingIncludesInterruptedFinalizationAndExcludesDurableDelivery() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let injector = BrowserIntakeIOInjector()
        let (store, authority) = try storeAndAuthority(directory.appendingPathComponent("spool"), projection: projection, injector: injector)
        let generation = try authority.publishEpoch(identityToken: "pending-finalizing")
        let period = try acceptedPeriod(authority, bytes: batch(generation: generation, id: 202))
        injector.setFailure { if $0 == .finalizePublication { throw BrowserRetiredTestFailure.injected } }
        #expect(throws: BrowserRetiredTestFailure.self) {
            try store.finalizePeriod(periodId: period, reason: "pending", civilDate: Date(timeIntervalSince1970: 1_700_000_101), timeZone: TimeZone(secondsFromGMT: 0)!)
        }
        injector.setFailure(nil)
        #expect(store.getPeriod(periodId: period)?.state == "finalizing")
        #expect(try #require(store.activePending()).identities.map(\.periodId) == [period])
        try store.finalizePeriod(periodId: period, reason: "recover", civilDate: Date(timeIntervalSince1970: 1_700_000_102), timeZone: TimeZone(secondsFromGMT: 0)!)
        let finalized = try #require(store.getPeriod(periodId: period))
        let binding = BrowserIngestAck(generation: generation, periodId: period,
            sha256: try #require(finalized.fileSha256), size: UInt64(finalized.committedLength), metadata: nil,
            requestedDay: try #require(finalized.requestedDay), requestedSegment: try #require(finalized.requestedSegment),
            canonicalKey: nil, status: .ok)
        #expect(try #require(store.activePending()).identities.map(\.periodId) == [period])
        try store.publishDeliveryAck(binding)
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: period).path))
        #expect(try #require(store.activePending()).identities.isEmpty)
        try store.releaseProven(periodId: period, binding: binding, nowMs: store.getFloorMs())
        #expect(try #require(store.activePending()).identities.isEmpty)
    }

    @Test(arguments: [BrowserIntakeIOPoint.retiredCatalogBootstrap, .retiredCatalogAttached, .retiredCatalogPublication])
    func catalogBootstrapRecoversOnlyItsDurableWitness(point: BrowserIntakeIOPoint) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool")
        let injector = BrowserIntakeIOInjector()
        injector.setFailure { if $0 == point { throw BrowserRetiredTestFailure.injected } }
        #expect(throws: BrowserRetiredTestFailure.self) {
            try BrowserIntakeStore(rootURL: spool, projection: projection, ioInjector: injector, metadataPageLimit: 256)
        }
        let recovered = try BrowserIntakeStore(rootURL: spool, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), metadataPageLimit: 256)
        #expect(recovered.retiredCustodyInventory() == .empty)
        #expect(!FileManager.default.fileExists(atPath: spool.appendingPathComponent("retired/catalog-bootstrap.json").path))
        #expect(!recovered.storeIsFailed())
    }

    @Test func interruptedRetiredCopyRecoversBeforeActiveDeletion() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool")
        let injector = BrowserIntakeIOInjector()
        var store: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: spool, projection: projection, ioInjector: injector, metadataPageLimit: 256)
        var authority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: store!, projection: projection,
            wallClock: { Date(timeIntervalSince1970: 1_700_000_100) })
        let generation = try authority!.publishEpoch(identityToken: "interrupted-retired-copy")
        let period = try acceptedPeriod(authority!, bytes: batch(generation: generation, id: 203))
        let original = try Data(contentsOf: store!.periodFileURL(for: period))
        injector.setFailure { if $0 == .retiredCatalogCopied { throw BrowserRetiredTestFailure.injected } }
        #expect(throws: BrowserRetiredTestFailure.self) { try authority!.retireIfTokenChanged(newToken: nil) }
        #expect(try Data(contentsOf: retiredPayload(spool, period)) == original)
        #expect(store!.getPeriod(periodId: period) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: spool.path).allSatisfy { !$0.hasPrefix("intake.sqlite-mj") })
        authority = nil
        store = nil
        let recovered = try BrowserIntakeStore(rootURL: spool, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), metadataPageLimit: 256)
        #expect(recovered.getPeriod(periodId: period) == nil)
        #expect(try Data(contentsOf: retiredPayload(spool, period)) == original)
        #expect(try recovered.lookupReceipt(generation: generation, inst: "retired-test-inst", batchId: String(format: "%032x", 203))?.result == "accepted")
        #expect(!recovered.storeIsFailed())
    }

    @Test func unprovenUUIDAcknowledgmentDirectoryIsRefusedAndPreserved() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool")
        let (store, _) = try storeAndAuthority(spool, projection: projection)
        let orphan = spool.appendingPathComponent("retired/periods/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        let ack = orphan.appendingPathComponent("browser_ingest_ack.json")
        let unknown = Data("unproven-ack".utf8)
        try unknown.write(to: ack)
        #expect(store.retiredCustodyInventory() == .unavailable)
        #expect(try Data(contentsOf: ack) == unknown)
    }

    @Test func retirementReplayInventoryPendingAndExplicitDiscard() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let (store, authority) = try storeAndAuthority(spool, projection: projection)
        let generation = try authority.publishEpoch(identityToken: "retired-identity-a")
        #expect(try #require(store.activePending()).identities.isEmpty)
        let bytes = try batch(generation: generation, id: 1, text: "exact retired payload")
        let periodId = try acceptedPeriod(authority, bytes: bytes)
        let activeURL = store.periodFileURL(for: periodId)
        let original = try Data(contentsOf: activeURL)

        #expect(try #require(store.activePending()).identities.map(\.periodId) == [periodId])
        try authority.retireIfTokenChanged(newToken: "retired-identity-a")
        #expect(store.getActiveGeneration() == generation)
        #expect(store.retiredCustodyInventory() == .empty)
        try authority.retireIfTokenChanged(newToken: nil)

        let retiredURL = retiredPayload(spool, periodId)
        #expect(try Data(contentsOf: retiredURL) == original)
        #expect(!FileManager.default.fileExists(atPath: activeURL.path))
        #expect(store.getPeriod(periodId: periodId) == nil)
        #expect(!store.getAllFinalizedPeriods().contains { $0.periodId == periodId })
        #expect(try #require(store.activePending()).identities.isEmpty)
        #expect(authority.status()["delivery"] as? String == "unknown")
        #expect(try store.lookupReceipt(generation: generation, inst: "retired-test-inst",
            batchId: String(format: "%032x", 1))?.result == "accepted")
        #expect(try authority.accept(bytes: bytes, direction: "extension_to_host")["result"] as? String == "duplicate")

        guard case .present(let scope) = store.retiredCustodyInventory() else {
            Issue.record("Retired inventory should contain the durable nonempty payload")
            return
        }
        #expect(scope.identities == [.init(generation: generation, periodId: periodId, committedLength: original.count)])
        let beforeCancel = try snapshotTree(spool)
        store.cancelRetiredCustodyDiscard()
        #expect(try snapshotTree(spool) == beforeCancel)

        let wrongScope = BrowserRetiredCustodyScope(identities: [])
        #expect(try store.discardRetiredCustody(wrongScope) == .refused)
        #expect(try Data(contentsOf: retiredURL) == original)
        #expect(try store.discardRetiredCustody(scope) == .fullyRemoved)
        #expect(store.retiredCustodyInventory() == .empty)
        #expect(FileManager.default.fileExists(atPath: retiredURL.path) == false)

        try authority.reconcileIdentity("mismatching-reload", mode: .reload)
        #expect(store.getActiveGeneration() == nil)
        try authority.reconcileIdentity(nil, mode: .replace)
        _ = try authority.publishEpoch(identityToken: "retired-identity-b")
        #expect(store.getActiveGeneration() != nil)
    }

    @Test func emptyRetirementDoesNotCreateInventory() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let (store, authority) = try storeAndAuthority(spool, projection: projection)

        let emptyGeneration = try authority.publishEpoch(identityToken: "empty-retirement")
        try authority.retireIfTokenChanged(newToken: nil)
        #expect(store.getActiveGeneration() == nil)
        #expect(store.retiredCustodyInventory() == .empty)
        #expect(try #require(store.activePending()).identities.isEmpty)
        #expect(authority.status()["delivery"] as? String == "unknown")

        let nonemptyGeneration = try authority.publishEpoch(identityToken: "nonempty-retirement")
        #expect(nonemptyGeneration != emptyGeneration)
        let periodId = try acceptedPeriod(authority, bytes: batch(generation: nonemptyGeneration,
            id: 111, text: "later retired bytes"))
        let activeBytes = try Data(contentsOf: store.periodFileURL(for: periodId))
        try authority.retireIfTokenChanged(newToken: nil)

        guard case .present(let scope) = store.retiredCustodyInventory() else {
            Issue.record("Expected only the later nonempty period in inventory")
            return
        }
        #expect(scope.identities.map(\.periodId) == [periodId])
        #expect(try Data(contentsOf: retiredPayload(spool, periodId)) == activeBytes)
    }

    @Test func discardScopeRefusesAfterAnotherGenerationRetires() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let (store, authority) = try storeAndAuthority(spool, projection: projection)

        let generationA = try authority.publishEpoch(identityToken: "scope-generation-a")
        let periodA = try acceptedPeriod(authority, bytes: batch(generation: generationA, id: 121, text: "payload A"))
        let bytesA = try Data(contentsOf: store.periodFileURL(for: periodA))
        try authority.retireIfTokenChanged(newToken: nil)
        guard case .present(let scopeA) = store.retiredCustodyInventory() else {
            Issue.record("Expected generation A in inventory")
            return
        }

        let generationB = try authority.publishEpoch(identityToken: "scope-generation-b")
        let periodB = try acceptedPeriod(authority, bytes: batch(generation: generationB, id: 122, text: "payload B"))
        let bytesB = try Data(contentsOf: store.periodFileURL(for: periodB))
        try authority.retireIfTokenChanged(newToken: nil)
        let discardIntent = spool.appendingPathComponent("retired/discard-intent.json")
        #expect(!FileManager.default.fileExists(atPath: discardIntent.path))

        #expect(try store.discardRetiredCustody(scopeA) == .refused)
        #expect(!FileManager.default.fileExists(atPath: discardIntent.path))
        #expect(try Data(contentsOf: retiredPayload(spool, periodA)) == bytesA)
        #expect(try Data(contentsOf: retiredPayload(spool, periodB)) == bytesB)
        guard case .present(let current) = store.retiredCustodyInventory() else {
            Issue.record("Both retired generations should remain in inventory")
            return
        }
        #expect(Set(current.identities.map(\.periodId)) == Set([periodA, periodB]))
    }

    @Test func identityRePairCreatesDistinctRetiredGenerations() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        var store: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: spool, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 1) }, metadataPageLimit: 256)
        var authority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: store!, projection: projection,
            wallClock: { Date(timeIntervalSince1970: 1_700_000_100) }, timeZone: TimeZone(secondsFromGMT: 0)!)

        let firstGeneration = try authority!.publishEpoch(identityToken: "journal-a")
        let firstPeriod = try acceptedPeriod(authority!, bytes: batch(generation: firstGeneration, id: 11))
        let firstBytes = try Data(contentsOf: store!.periodFileURL(for: firstPeriod))
        #expect(try authority!.publishEpoch(identityToken: "journal-a") == firstGeneration)
        #expect(FileManager.default.fileExists(atPath: store!.periodFileURL(for: firstPeriod).path))

        let secondGeneration = try authority!.publishEpoch(identityToken: "journal-b")
        #expect(secondGeneration != firstGeneration)
        #expect(try Data(contentsOf: retiredPayload(spool, firstPeriod)) == firstBytes)
        let secondPeriod = try acceptedPeriod(authority!, bytes: batch(generation: secondGeneration, id: 12))
        let secondBytes = try Data(contentsOf: store!.periodFileURL(for: secondPeriod))

        let thirdGeneration = try authority!.publishEpoch(identityToken: "journal-a")
        #expect(thirdGeneration != firstGeneration)
        #expect(thirdGeneration != secondGeneration)
        #expect(try Data(contentsOf: retiredPayload(spool, secondPeriod)) == secondBytes)
        let thirdPeriod = try acceptedPeriod(authority!, bytes: batch(generation: thirdGeneration, id: 13))
        let thirdBytes = try Data(contentsOf: store!.periodFileURL(for: thirdPeriod))

        try authority!.retireIfTokenChanged(newToken: nil)
        #expect(store!.getActiveGeneration() == nil)
        let fourthGeneration = try authority!.publishEpoch(identityToken: "journal-a")
        #expect(fourthGeneration != thirdGeneration)
        #expect(try Data(contentsOf: retiredPayload(spool, thirdPeriod)) == thirdBytes)
        #expect(!store!.getAllFinalizedPeriods().contains { $0.periodId == firstPeriod || $0.periodId == secondPeriod || $0.periodId == thirdPeriod })
        try authority!.retireIfTokenChanged(newToken: nil)
        #expect(authority!.status()["delivery"] as? String == "unknown")

        let stale = try authority!.accept(bytes: batch(generation: firstGeneration, id: 99), direction: "extension_to_host")
        #expect(stale["reason"] as? String == "stale_generation")
        guard case .present(let inventory) = store!.retiredCustodyInventory() else {
            Issue.record("Expected each retired identity in inventory")
            return
        }
        #expect(Set(inventory.identities.map(\.periodId)) == Set([firstPeriod, secondPeriod, thirdPeriod]))
        #expect(try Data(contentsOf: retiredPayload(spool, firstPeriod)) == firstBytes)
        #expect(try Data(contentsOf: retiredPayload(spool, secondPeriod)) == secondBytes)
        #expect(try Data(contentsOf: retiredPayload(spool, thirdPeriod)) == thirdBytes)

        authority = nil
        store = nil
    }

    @Test func nearCeilingRetirementLetsSuccessorsFitTheActiveSpool() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try copiedProjection(in: directory, spoolBytes: 6_000_000)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let (store, authority) = try storeAndAuthority(spool, projection: projection)

        let firstGeneration = try authority.publishEpoch(identityToken: "near-ceiling-a")
        let firstBytes = try mediumBatch(generation: firstGeneration, id: 61, marker: "A", blockCount: 550)
        let firstReply = try authority.accept(bytes: firstBytes, direction: "extension_to_host")
        #expect(firstReply["result"] as? String == "accepted")
        let firstPeriod = try #require(firstReply["period_id"] as? String)
        let firstPayload = try Data(contentsOf: store.periodFileURL(for: firstPeriod))
        #expect(firstPayload.count > 1_000_000)
        #expect(store.projectedSpoolBytes() < projection.policy.spoolBytes)

        let modest = try mediumBatch(generation: firstGeneration, id: 62, marker: "M", blockCount: 150)
        #expect(store.projectedSpoolBytes(additionalPayloadBytes: modest.count) > projection.policy.spoolBytes)
        let refused = try authority.accept(bytes: modest, direction: "extension_to_host")
        #expect(refused["reason"] as? String == "resource_exhausted")

        let secondGeneration = try authority.publishEpoch(identityToken: "near-ceiling-b")
        #expect(try Data(contentsOf: retiredPayload(spool, firstPeriod)) == firstPayload)
        let secondPeriod = try acceptedPeriod(authority, bytes: batch(generation: secondGeneration, id: 63, text: "successor batch"))
        try store.finalizePeriod(periodId: secondPeriod, reason: "seal", civilDate: Date(timeIntervalSince1970: 1_700_000_100), timeZone: TimeZone(secondsFromGMT: 0)!)
        let secondPayload = try Data(contentsOf: store.periodFileURL(for: secondPeriod))

        let thirdGeneration = try authority.publishEpoch(identityToken: "near-ceiling-c")
        #expect(try Data(contentsOf: retiredPayload(spool, firstPeriod)) == firstPayload)
        #expect(try Data(contentsOf: retiredPayload(spool, secondPeriod)) == secondPayload)
        let thirdPeriod = try acceptedPeriod(authority, bytes: batch(generation: thirdGeneration, id: 64, text: "current batch"))
        try store.finalizePeriod(periodId: thirdPeriod, reason: "seal", civilDate: Date(timeIntervalSince1970: 1_700_000_100), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(store.projectedSpoolBytes() < projection.policy.spoolBytes)
        #expect(store.getAllFinalizedPeriods().map(\.periodId) == [thirdPeriod])
    }

    @Test func retiredDeliveryAndStaleFactsDoNotCarryIntoSuccessor() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let (store, authority) = try storeAndAuthority(spool, projection: projection)

        let oldGeneration = try authority.publishEpoch(identityToken: "failure-isolation-a")
        let oldPeriod = try acceptedPeriod(authority, bytes: batch(generation: oldGeneration, id: 71))
        let earliest = store.getEarliestHeldMs()
        #expect(earliest > 0)
        _ = try store.updateStaleness(anchorMs: earliest, elapsedMs: projection.policy.spoolAgeMs)
        store.setDeliveryFailure("relay_unavailable")
        #expect((authority.status()["custody"] as? [String: Bool])?["stale"] == true)
        #expect(authority.status()["delivery"] as? String == "failed")

        let nextGeneration = try authority.publishEpoch(identityToken: "failure-isolation-b")
        #expect(store.getPeriod(periodId: oldPeriod) == nil)
        let cleanStatus = authority.status()
        #expect(cleanStatus["delivery"] as? String == "idle")
        #expect(cleanStatus["failure"] == nil)
        #expect((cleanStatus["custody"] as? [String: Bool])?["stale"] == false)

        let activePeriod = try acceptedPeriod(authority, bytes: batch(generation: nextGeneration, id: 72))
        #expect(authority.status()["delivery"] as? String == "kept_locally")
        #expect(!store.setDeliveryFailure("local_io", forGeneration: oldGeneration))
        #expect(!store.setStoreFailed(true, forGeneration: oldGeneration))
        #expect(!store.storeIsFailed())
        #expect(authority.status()["delivery"] as? String == "kept_locally")
        #expect(authority.status()["failure"] == nil)
        #expect(store.getPeriod(periodId: activePeriod)?.generation == nextGeneration)

        #expect(store.setDeliveryFailure("relay_unavailable", forGeneration: nextGeneration))
        #expect(authority.status()["delivery"] as? String == "failed")
        #expect(authority.status()["failure"] as? String == "relay_unavailable")
    }

    @Test func discardAllKeepsReloadFenceAndExplicitOwnerReplacementCanPublish() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        var store: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: spool, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 1) }, metadataPageLimit: 256)
        var authority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: store!, projection: projection,
            wallClock: { Date(timeIntervalSince1970: 1_700_000_100) }, timeZone: TimeZone(secondsFromGMT: 0)!)
        let generation = try authority!.publishEpoch(identityToken: "discarded-identity")
        let period = try acceptedPeriod(authority!, bytes: batch(generation: generation, id: 81))
        try authority!.retireIfTokenChanged(newToken: nil)
        guard case .present(let scope) = store!.retiredCustodyInventory() else {
            Issue.record("Expected retired payload before explicit discard")
            return
        }
        #expect(try store!.discardRetiredCustody(scope) == .fullyRemoved)
        #expect(store!.retiredCustodyInventory() == .empty)
        authority = nil
        store = nil

        let owner = try BrowserIntakeOwner.start(spoolRoot: spool, projection: projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: "mismatching-reload"),
            transport: RetiredRecordingTransport(), routeResolver: HomeBaseURLResolver { .held },
            ioInjector: BrowserIntakeIOInjector())
        defer { owner.stop() }
        #expect(owner.store.getActiveGeneration() == nil)
        #expect(owner.authority.status()["capture"] as? String == "unavailable")
        #expect(owner.retiredCustodyInventory() == .empty)
        try owner.credentialReloaded(identityToken: "stale-reload")
        #expect(owner.store.getActiveGeneration() == nil)
        try owner.credentialWillChange(identityToken: nil, browserWarningWasPresented: true)
        try owner.credentialDidChange(identityToken: "explicit-replacement")
        #expect(owner.store.getActiveGeneration() != nil)
        #expect(owner.authority.isAdmissionOpen())
        #expect(owner.store.getPeriod(periodId: period) == nil)
    }

    @Test func activeAcceptSurvivesConcurrentRetiredDiscard() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let (store, authority) = try storeAndAuthority(spool, projection: projection)
        let oldGeneration = try authority.publishEpoch(identityToken: "concurrent-discard-a")
        let oldPeriod = try acceptedPeriod(authority, bytes: batch(generation: oldGeneration, id: 91))
        try authority.retireIfTokenChanged(newToken: nil)
        guard case .present(let scope) = store.retiredCustodyInventory() else {
            Issue.record("Expected retired payload before discard")
            return
        }
        let activeGeneration = try authority.publishEpoch(identityToken: "concurrent-discard-b")
        let activeBytes = try batch(generation: activeGeneration, id: 92)
        async let discarded = Task.detached { try store.discardRetiredCustody(scope) }.value
        async let accepted = Task.detached {
            let reply = try authority.accept(bytes: activeBytes, direction: "extension_to_host")
            return (reply["result"] as? String, reply["period_id"] as? String)
        }.value
        let (discardResult, acceptReply) = try await (discarded, accepted)
        #expect(discardResult == .fullyRemoved)
        #expect(acceptReply.0 == "accepted")
        #expect(store.getActiveGeneration() == activeGeneration)
        #expect(try store.lookupReceipt(generation: activeGeneration, inst: "retired-test-inst",
            batchId: String(format: "%032x", 92))?.result == "accepted")
        #expect(FileManager.default.fileExists(atPath: retiredPayload(spool, oldPeriod).path) == false)
    }

    @Test(arguments: [false, true])
    func constrainedRestartExcludesThreeRetiredPayloadsAndUploadsOnlyActiveSuccessor(restart: Bool) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lowProjection = try copiedProjection(in: directory, spoolBytes: 10_000_000)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        var store: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: spool, projection: lowProjection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 1) }, metadataPageLimit: 256)
        let clock = BrowserRetiredTestClock()
        var authority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: store!, projection: lowProjection,
            wallClock: { clock.date }, timeZone: TimeZone(secondsFromGMT: 0)!)

        let firstGeneration = try authority!.publishEpoch(identityToken: "large-identity-a")
        let firstPeriod = try acceptedPeriod(authority!, bytes: largeBatch(generation: firstGeneration, marker: "A"))
        let firstBytes = try Data(contentsOf: store!.periodFileURL(for: firstPeriod))
        #expect(firstBytes.count >= 2_900_000)

        let secondGeneration = try authority!.publishEpoch(identityToken: "large-identity-b")
        let secondPeriod = try acceptedPeriod(authority!, bytes: largeBatch(generation: secondGeneration, marker: "B"))
        let secondBytes = try Data(contentsOf: store!.periodFileURL(for: secondPeriod))
        try store!.finalizePeriod(periodId: secondPeriod, reason: "seal", civilDate: clock.date, timeZone: TimeZone(secondsFromGMT: 0)!)

        let thirdGeneration = try authority!.publishEpoch(identityToken: "large-identity-c")
        let thirdPeriod = try acceptedPeriod(authority!, bytes: largeBatch(generation: thirdGeneration, marker: "C"))
        let thirdBytes = try Data(contentsOf: store!.periodFileURL(for: thirdPeriod))

        let activeGeneration = try authority!.publishEpoch(identityToken: "small-successor-c")
        let activeBytes = try batch(generation: activeGeneration, id: 3, text: "only active successor")
        let activePeriod = try acceptedPeriod(authority!, bytes: activeBytes)
        #expect(try Data(contentsOf: retiredPayload(spool, firstPeriod)) == firstBytes)
        #expect(try Data(contentsOf: retiredPayload(spool, secondPeriod)) == secondBytes)
        #expect(try Data(contentsOf: retiredPayload(spool, thirdPeriod)) == thirdBytes)
        #expect(store!.getOpenPeriodId() == activePeriod)
        authority = nil
        let reopened: BrowserIntakeStore
        if restart {
            store = nil
            reopened = try BrowserIntakeStore(rootURL: spool, projection: lowProjection,
                ioInjector: BrowserIntakeIOInjector(), ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 2) }, metadataPageLimit: 256)
        } else {
            reopened = try #require(store)
        }
        #expect(reopened.getActiveGeneration() == activeGeneration)
        #expect(try reopened.lookupReceipt(generation: firstGeneration, inst: "retired-large-inst",
            batchId: String(format: "%032x", 0)) == nil)
        #expect(reopened.getOpenPeriodId() == activePeriod)
        #expect(reopened.projectedSpoolBytes() < lowProjection.policy.spoolBytes)
        #expect(firstBytes.count + secondBytes.count + thirdBytes.count + reopened.projectedSpoolBytes() > lowProjection.policy.spoolBytes)
        let acceptanceAuthority = BrowserIntakeAuthority(store: reopened, projection: lowProjection,
            wallClock: { clock.date }, timeZone: TimeZone(secondsFromGMT: 0)!)
        try acceptanceAuthority.reconcileIdentity("small-successor-c", mode: .reload)
        let nextBytes = try batch(generation: activeGeneration, id: 4, text: "next active batch")
        let next = try acceptanceAuthority.accept(bytes: nextBytes,
            direction: "extension_to_host")
        #expect(next["result"] as? String == "accepted")
        #expect(next["period_id"] as? String == activePeriod)
        try reopened.finalizePeriod(periodId: activePeriod, reason: "seal", civilDate: clock.date, timeZone: TimeZone(secondsFromGMT: 0)!)
        let activePayload = try Data(contentsOf: reopened.periodFileURL(for: activePeriod))

        let gate = BrowserUploadGate(store: reopened)
        let route = BrowserIntakeRouteState()
        _ = route.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1",
            identityDigest: BrowserIntakeStore.identityDigest(of: "small-successor-c"), pairingGeneration: 1,
            transportIncarnation: 1, credentialIsCurrent: { true }))
        let transport = RetiredRecordingTransport()
        let planner = BrowserUploadPlanner(store: reopened, gate: gate, client: transport,
            nowMs: { 1_700_000_100_000 }, routeState: route)
        await planner.planAndUpload()
        let body = try #require(transport.uploadedBody)
        #expect(body.range(of: activePayload) != nil)
        #expect(body.range(of: firstBytes) == nil)
        #expect(body.range(of: secondBytes) == nil)
        #expect(body.range(of: thirdBytes) == nil)

        let deliveredAck = try #require(try BrowserIngestAckStore.read(from: BrowserIngestAckStore.ackURL(
            periodDirectory: reopened.periodFileURL(for: activePeriod).deletingLastPathComponent())))
        let canonicalKey = try #require(deliveredAck.canonicalKey)
        transport.setDayListing(.init(total: 1, items: [.init(key: canonicalKey,
            files: [.init(name: deliveredAck.filename, size: deliveredAck.size, sha256: deliveredAck.sha256, status: .present)],
            originalKey: deliveredAck.requestedSegment)]))
        await planner.planAndUpload()
        #expect(reopened.getPeriod(periodId: activePeriod)?.state == "delivered")
        #expect(try Data(contentsOf: retiredPayload(spool, firstPeriod)) == firstBytes)
        #expect(try Data(contentsOf: retiredPayload(spool, secondPeriod)) == secondBytes)
        #expect(try Data(contentsOf: retiredPayload(spool, thirdPeriod)) == thirdBytes)
    }

    @Test func transitionFailureLeavesLegacyBytesAndDurablePublicationRecovers() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let injector = BrowserIntakeIOInjector()
        var store: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: spool, projection: projection, ioInjector: injector,
            ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 1) }, metadataPageLimit: 256)
        let clock = BrowserRetiredTestClock()
        var authority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: store!, projection: projection, wallClock: { clock.date })
        let generation = try authority!.publishEpoch(identityToken: "legacy-identity")
        let periodId = try acceptedPeriod(authority!, bytes: batch(generation: generation, id: 41))
        let activeURL = store!.periodFileURL(for: periodId)
        let original = try Data(contentsOf: activeURL)
        injector.setFailure { point in
            if point == .retiredTransitionIntent { throw BrowserRetiredTestFailure.injected }
        }
        #expect(throws: BrowserRetiredTestFailure.self) { try authority!.retireIfTokenChanged(newToken: nil) }
        #expect(try Data(contentsOf: activeURL) == original)
        #expect(!FileManager.default.fileExists(atPath: spool.appendingPathComponent("retired/transition.json").path))
        authority = nil
        store = nil

        var upgraded: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: spool, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 2) }, metadataPageLimit: 256)
        #expect(upgraded!.getActiveGeneration() == nil)
        #expect(upgraded!.getPeriod(periodId: periodId) == nil)
        #expect(try Data(contentsOf: retiredPayload(spool, periodId)) == original)
        #expect(try upgraded!.lookupReceipt(generation: generation, inst: "retired-test-inst",
            batchId: String(format: "%032x", 41))?.result == "accepted")

        var crashAuthority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: upgraded!, projection: projection,
            wallClock: { clock.date }, timeZone: TimeZone(secondsFromGMT: 0)!)
        let crashGeneration = try crashAuthority!.publishEpoch(identityToken: "published-transition-identity")
        let crashPeriod = try acceptedPeriod(crashAuthority!, bytes: batch(generation: crashGeneration, id: 42))
        let crashActiveURL = upgraded!.periodFileURL(for: crashPeriod)
        let crashBytes = try Data(contentsOf: crashActiveURL)
        upgraded!.crashPoint = .afterRetiredPublication
        #expect(throws: (any Error).self) { try crashAuthority!.retireIfTokenChanged(newToken: nil) }
        let crashRetiredURL = retiredPayload(spool, crashPeriod)
        #expect(!FileManager.default.fileExists(atPath: crashActiveURL.path))
        #expect(try Data(contentsOf: crashRetiredURL) == crashBytes)
        #expect(upgraded!.getActiveGeneration() == nil)
        crashAuthority = nil
        upgraded = nil

        let recovered = try BrowserIntakeStore(rootURL: spool, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 3) }, metadataPageLimit: 256)
        #expect(recovered.getActiveGeneration() == nil)
        #expect(recovered.getPeriod(periodId: crashPeriod) == nil)
        #expect(!recovered.getAllFinalizedPeriods().contains { $0.periodId == crashPeriod })
        #expect(try Data(contentsOf: crashRetiredURL) == crashBytes)
        guard case .present(let recoveredInventory) = recovered.retiredCustodyInventory() else {
            Issue.record("Published transition recovery should retain both identities")
            return
        }
        #expect(recoveredInventory.identities.count == 2)
    }

    @Test func discardFailureOutcomesAndRecoveryStayInsideConfirmedScope() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let injector = BrowserIntakeIOInjector()
        let (store, authority) = try storeAndAuthority(spool, projection: projection, injector: injector)
        let firstGeneration = try authority.publishEpoch(identityToken: "discard-a")
        let firstPeriod = try acceptedPeriod(authority, bytes: batch(generation: firstGeneration, id: 51))
        let firstBytes = try Data(contentsOf: store.periodFileURL(for: firstPeriod))
        try authority.retireIfTokenChanged(newToken: nil)
        let secondGeneration = try authority.publishEpoch(identityToken: "discard-b")
        let secondPeriod = try acceptedPeriod(authority, bytes: batch(generation: secondGeneration, id: 52))
        let secondBytes = try Data(contentsOf: store.periodFileURL(for: secondPeriod))
        try authority.retireIfTokenChanged(newToken: nil)
        guard case .present(let oldScope) = store.retiredCustodyInventory() else {
            Issue.record("Expected two retired identities")
            return
        }

        let activeGeneration = try authority.publishEpoch(identityToken: "discard-active-c")
        let activeBytes = try batch(generation: activeGeneration, id: 53)
        #expect(try authority.accept(bytes: activeBytes, direction: "extension_to_host")["result"] as? String == "accepted")
        #expect(try store.discardRetiredCustody(oldScope) == .fullyRemoved)
        #expect(store.getActiveGeneration() == activeGeneration)
        #expect(try store.lookupReceipt(generation: activeGeneration, inst: "retired-test-inst",
            batchId: String(format: "%032x", 53))?.result == "accepted")
        #expect(store.retiredCustodyInventory() == .empty)
        #expect(FileManager.default.fileExists(atPath: retiredPayload(spool, firstPeriod).path) == false)
        #expect(FileManager.default.fileExists(atPath: retiredPayload(spool, secondPeriod).path) == false)
        #expect(firstBytes != secondBytes)

        // Intent publication failure performs no unlink and leaves the durable inventory intact.
        try authority.retireIfTokenChanged(newToken: nil)
        let thirdGeneration = try authority.publishEpoch(identityToken: "discard-active-d")
        let thirdPeriod = try acceptedPeriod(authority, bytes: batch(generation: thirdGeneration, id: 54))
        try authority.retireIfTokenChanged(newToken: nil)
        guard case .present(let thirdScope) = store.retiredCustodyInventory() else {
            Issue.record("Expected another retired identity")
            return
        }
        injector.setFailure { point in
            if point == .retiredDiscardIntent { throw BrowserRetiredTestFailure.injected }
        }
        #expect(throws: BrowserRetiredTestFailure.self) { try store.discardRetiredCustody(thirdScope) }
        #expect(FileManager.default.fileExists(atPath: retiredPayload(spool, thirdPeriod).path))
        injector.setFailure { point in
            if point == .retiredUnlink { throw BrowserRetiredTestFailure.injected }
        }
        #expect(try store.discardRetiredCustody(thirdScope) == .nothingRemoved)
        #expect(FileManager.default.fileExists(atPath: retiredPayload(spool, thirdPeriod).path))
        injector.setFailure { point in
            if point == .retiredDirectorySync { throw BrowserRetiredTestFailure.injected }
        }
        #expect(try store.discardRetiredCustody(thirdScope) == .durabilityUnproven)
        injector.setFailure(nil)
        let recovered = try BrowserIntakeStore(rootURL: spool, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 3) }, metadataPageLimit: 256)
        #expect(recovered.getActiveGeneration() == nil)
        #expect(recovered.retiredCustodyInventory() == .empty)
    }

    @Test func durableDiscardRecoveryDoesNotTouchLaterCustody() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let injector = BrowserIntakeIOInjector()
        var store: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: spool, projection: projection,
            ioInjector: injector, ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 1) }, metadataPageLimit: 256)
        var authority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: store!, projection: projection,
            wallClock: { Date(timeIntervalSince1970: 1_700_000_100) }, timeZone: TimeZone(secondsFromGMT: 0)!)

        let generationA = try authority!.publishEpoch(identityToken: "discard-recovery-a")
        let periodA = try acceptedPeriod(authority!, bytes: batch(generation: generationA, id: 131, text: "discarded A"))
        let bytesA = try Data(contentsOf: store!.periodFileURL(for: periodA))
        try authority!.retireIfTokenChanged(newToken: nil)
        guard case .present(let scopeA) = store!.retiredCustodyInventory() else {
            Issue.record("Expected A before discard")
            return
        }

        injector.setFailure { point in
            if point == .retiredDirectorySync { throw BrowserRetiredTestFailure.injected }
        }
        #expect(try store!.discardRetiredCustody(scopeA) == .durabilityUnproven)
        #expect(FileManager.default.fileExists(atPath: retiredPayload(spool, periodA).path) == false)
        #expect(FileManager.default.fileExists(atPath: spool.appendingPathComponent("retired/discard-intent.json").path))
        injector.setFailure(nil)

        let generationB = try authority!.publishEpoch(identityToken: "discard-recovery-b")
        let periodB = try acceptedPeriod(authority!, bytes: batch(generation: generationB, id: 132, text: "retained B"))
        let bytesB = try Data(contentsOf: store!.periodFileURL(for: periodB))
        try authority!.retireIfTokenChanged(newToken: nil)

        let generationC = try authority!.publishEpoch(identityToken: "discard-recovery-c")
        let bytesC = try batch(generation: generationC, id: 133, text: "active C")
        let periodC = try acceptedPeriod(authority!, bytes: bytesC)
        try store!.finalizePeriod(periodId: periodC, reason: "seal", civilDate: Date(timeIntervalSince1970: 1_700_000_100),
            timeZone: TimeZone(secondsFromGMT: 0)!)
        let payloadC = try Data(contentsOf: store!.periodFileURL(for: periodC))
        authority = nil
        store = nil

        let recovered = try BrowserIntakeStore(rootURL: spool, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: { BrowserAgeStamp(bootID: "retired-test-boot", elapsedMs: 2) }, metadataPageLimit: 256)
        #expect(recovered.getActiveGeneration() == generationC)
        #expect(recovered.getPeriod(periodId: periodC)?.generation == generationC)
        #expect(try Data(contentsOf: recovered.periodFileURL(for: periodC)) == payloadC)
        #expect(!recovered.getAllFinalizedPeriods().contains { $0.periodId == periodA })
        #expect(!recovered.getAllFinalizedPeriods().contains { $0.periodId == periodB })
        #expect(try Data(contentsOf: retiredPayload(spool, periodB)) == bytesB)
        #expect(!FileManager.default.fileExists(atPath: retiredPayload(spool, periodA).path))
        guard case .present(let inventory) = recovered.retiredCustodyInventory() else {
            Issue.record("B should remain in retired inventory after recovery")
            return
        }
        #expect(inventory.identities.map(\.periodId) == [periodB])

        let recoveredAuthority = BrowserIntakeAuthority(store: recovered, projection: projection,
            wallClock: { Date(timeIntervalSince1970: 1_700_000_100) }, timeZone: TimeZone(secondsFromGMT: 0)!)
        try recoveredAuthority.reconcileIdentity("discard-recovery-c", mode: .reload)
        let route = BrowserIntakeRouteState()
        _ = route.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1",
            identityDigest: BrowserIntakeStore.identityDigest(of: "discard-recovery-c"), pairingGeneration: 1,
            transportIncarnation: 1, credentialIsCurrent: { true }))
        let transport = RetiredRecordingTransport()
        let planner = BrowserUploadPlanner(store: recovered, gate: BrowserUploadGate(store: recovered), client: transport,
            nowMs: { 1_700_000_100_000 }, routeState: route)
        await planner.planAndUpload()
        let uploadedBody = try #require(transport.uploadedBody)
        #expect(uploadedBody.range(of: payloadC) != nil)
        #expect(uploadedBody.range(of: bytesA) == nil)
        #expect(uploadedBody.range(of: bytesB) == nil)
    }

    @Test func staleUploadCleanupDropsTheRetiredReservation() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        let (store, authority) = try storeAndAuthority(spool, projection: projection)

        let generationA = try authority.publishEpoch(identityToken: "staged-generation-a")
        let periodA = try acceptedPeriod(authority, bytes: batch(generation: generationA, id: 141, text: "staged payload A"))
        try store.finalizePeriod(periodId: periodA, reason: "seal", civilDate: Date(timeIntervalSince1970: 1_700_000_100),
            timeZone: TimeZone(secondsFromGMT: 0)!)
        let bytesA = try Data(contentsOf: store.periodFileURL(for: periodA))
        let routeA = BrowserIntakeRouteState()
        _ = routeA.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1",
            identityDigest: BrowserIntakeStore.identityDigest(of: "staged-generation-a"), pairingGeneration: 1,
            transportIncarnation: 1, credentialIsCurrent: { true }))
        let blockedTransport = SuspendedRetiredTransport()
        let plannerA = BrowserUploadPlanner(store: store, gate: BrowserUploadGate(store: store), client: blockedTransport,
            nowMs: { 1_700_000_100_000 }, routeState: routeA)
        let before = store.projectedSpoolBytes()
        let uploadTask = Task { await plannerA.planAndUpload() }
        defer { blockedTransport.resume() }
        #expect(await blockedTransport.waitUntilSuspended())
        #expect(blockedTransport.stagedBodyExisted)
        #expect(blockedTransport.uploadedBody == nil)
        let stagingRoot = store.stagingRootURL()
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
            .contains { $0.hasPrefix("browser-upload-") })

        let generationB = try authority.publishEpoch(identityToken: "staged-generation-b")
        let after = store.projectedSpoolBytes()
        #expect(after + bytesA.count + 32 * 1024 < before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
            .contains { $0.hasPrefix("browser-upload-") } == false)
        let retiredFile = retiredPayload(spool, periodA)
        #expect(try Data(contentsOf: retiredFile) == bytesA)

        blockedTransport.resume()
        await uploadTask.value
        #expect(blockedTransport.uploadedBody == nil)
        #expect(store.projectedSpoolBytes() == after)
        #expect(store.getActiveGeneration() == generationB)
        #expect(!store.storeIsFailed())
        #expect(authority.status()["delivery"] as? String == "idle")
        #expect(authority.status()["failure"] == nil)

        let bytesB = try batch(generation: generationB, id: 142, text: "successor payload B")
        let periodB = try acceptedPeriod(authority, bytes: bytesB)
        try store.finalizePeriod(periodId: periodB, reason: "seal", civilDate: Date(timeIntervalSince1970: 1_700_000_100),
            timeZone: TimeZone(secondsFromGMT: 0)!)
        let payloadB = try Data(contentsOf: store.periodFileURL(for: periodB))
        let routeB = BrowserIntakeRouteState()
        _ = routeB.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1",
            identityDigest: BrowserIntakeStore.identityDigest(of: "staged-generation-b"), pairingGeneration: 1,
            transportIncarnation: 2, credentialIsCurrent: { true }))
        let transportB = RetiredRecordingTransport()
        let plannerB = BrowserUploadPlanner(store: store, gate: BrowserUploadGate(store: store), client: transportB,
            nowMs: { 1_700_000_100_000 }, routeState: routeB)
        await plannerB.planAndUpload()
        let bodyB = try #require(transportB.uploadedBody)
        #expect(bodyB.range(of: payloadB) != nil)
        #expect(bodyB.range(of: bytesA) == nil)
        #expect(try Data(contentsOf: retiredFile) == bytesA)
    }

    @Test func unknownRetiredChildFailsClosedWithoutDeletingIt() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = directory.appendingPathComponent("spool", isDirectory: true)
        var store: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: spool, projection: projection)
        #expect(!store!.storeIsFailed())
        let unknown = spool.appendingPathComponent("retired/periods/unrecognized-child")
        try Data("keep".utf8).write(to: unknown)
        #expect(store!.retiredCustodyInventory() == .unavailable)
        #expect(try Data(contentsOf: unknown) == Data("keep".utf8))
        store = nil
        #expect(throws: BrowserIntakeStoreError.self) { try BrowserIntakeStore(rootURL: spool, projection: projection) }
        #expect(try Data(contentsOf: unknown) == Data("keep".utf8))
    }

    @Test func missingPayloadMalformedCatalogWrongTypeAndSymlinkFailClosed() throws {
        let projection = try BrowserContractProjection(rootURL: vendorURL)

        let missingRoot = try root()
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        let missingSpool = missingRoot.appendingPathComponent("spool", isDirectory: true)
        var missingStore: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: missingSpool, projection: projection)
        var missingAuthority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: missingStore!, projection: projection,
            wallClock: { Date(timeIntervalSince1970: 1_700_000_100) })
        let missingGeneration = try missingAuthority!.publishEpoch(identityToken: "missing-payload")
        let missingPeriod = try acceptedPeriod(missingAuthority!, bytes: batch(generation: missingGeneration, id: 101))
        try missingAuthority!.retireIfTokenChanged(newToken: nil)
        let missingPayload = retiredPayload(missingSpool, missingPeriod)
        let catalogBeforeMissing = try Data(contentsOf: missingSpool.appendingPathComponent("retired/catalog.sqlite"))
        missingAuthority = nil
        missingStore = nil
        try FileManager.default.removeItem(at: missingPayload)
        #expect(throws: BrowserIntakeStoreError.self) { try BrowserIntakeStore(rootURL: missingSpool, projection: projection) }
        #expect(try Data(contentsOf: missingSpool.appendingPathComponent("retired/catalog.sqlite")) == catalogBeforeMissing)
        #expect(FileManager.default.fileExists(atPath: missingPayload.deletingLastPathComponent().path))

        let malformedRoot = try root()
        defer { try? FileManager.default.removeItem(at: malformedRoot) }
        let malformedSpool = malformedRoot.appendingPathComponent("spool", isDirectory: true)
        do { _ = try BrowserIntakeStore(rootURL: malformedSpool, projection: projection) }
        let catalog = malformedSpool.appendingPathComponent("retired/catalog.sqlite")
        try Data("malformed catalog".utf8).write(to: catalog)
        let malformedBytes = try Data(contentsOf: catalog)
        #expect(throws: BrowserIntakeStoreError.self) { try BrowserIntakeStore(rootURL: malformedSpool, projection: projection) }
        #expect(try Data(contentsOf: catalog) == malformedBytes)

        let wrongTypeRoot = try root()
        defer { try? FileManager.default.removeItem(at: wrongTypeRoot) }
        let wrongTypeSpool = wrongTypeRoot.appendingPathComponent("spool", isDirectory: true)
        do { _ = try BrowserIntakeStore(rootURL: wrongTypeSpool, projection: projection) }
        let wrongType = wrongTypeSpool.appendingPathComponent("retired/periods/\(UUID().uuidString)/browser_pages.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongType, withIntermediateDirectories: true)
        #expect(throws: BrowserIntakeStoreError.self) { try BrowserIntakeStore(rootURL: wrongTypeSpool, projection: projection) }
        #expect(FileManager.default.fileExists(atPath: wrongType.path))

        let symlinkRoot = try root()
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let symlinkSpool = symlinkRoot.appendingPathComponent("spool", isDirectory: true)
        var symlinkStore: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: symlinkSpool, projection: projection)
        let target = symlinkRoot.appendingPathComponent("target")
        try Data("keep target".utf8).write(to: target)
        let symlink = symlinkSpool.appendingPathComponent("retired/periods/\(UUID().uuidString)/browser_pages.jsonl")
        try FileManager.default.createDirectory(at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: target.path)
        #expect(symlinkStore!.retiredCustodyInventory() == .unavailable)
        #expect(try Data(contentsOf: target) == Data("keep target".utf8))
        #expect(FileManager.default.fileExists(atPath: symlink.path))
        symlinkStore = nil
        #expect(throws: BrowserIntakeStoreError.self) { try BrowserIntakeStore(rootURL: symlinkSpool, projection: projection) }
        #expect(try Data(contentsOf: target) == Data("keep target".utf8))
    }
}

private final class RetiredRecordingTransport: BrowserUploadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var listing = IngestProtocolV3.SegmentsDay(total: 0, items: [])
    private var body: Data?

    var uploadedBody: Data? { lock.withLock { body } }

    func setDayListing(_ value: IngestProtocolV3.SegmentsDay) {
        lock.withLock { listing = value }
    }

    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay {
        lock.withLock { listing }
    }

    func prepareUpload(serverURL: String, day: String, segment: String, mediaFiles: [URL],
                       metadata: [String: IngestJSONValue]?, source: String?, boundary: String,
                       bodyURL: URL, ioInjector: BrowserIntakeIOInjector) throws -> PreparedIngestV3Upload {
        try IngestV3UploadRequestBuilder.build(baseURL: serverURL, day: day, segment: segment,
            selectedFiles: mediaFiles, meta: metadata, source: source, boundary: boundary, bodyURL: bodyURL,
            ioHooks: .browser(using: ioInjector))
    }

    func uploadStaged(prepared: PreparedIngestV3Upload, lease: BrowserUploadLease) async -> UploadResult {
        guard lease.isValid(), let part = prepared.stagedParts.first,
              let body = try? Data(contentsOf: prepared.bodyURL) else { return .failure(URLError(.cancelled)) }
        lock.withLock { self.body = body }
        let response = IngestProtocolV3.UploadResponse(status: .collision, storedSegmentKey: "120001_1",
            segmentOriginal: prepared.submittedSegment,
            fileDescriptors: [.init(submitted: part.submitted, written: part.written, size: part.size,
                sha256: part.sha256, disposition: .written)], meta: prepared.metadata ?? [:])
        return .success(UploadSuccessInfo(response: response))
    }
}

private final class SuspendedRetiredTransport: BrowserUploadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var stagedFileExisted = false
    private var sentBody: Data?
    private var released = false
    private let suspendListing: Bool

    init(suspendListing: Bool = false) { self.suspendListing = suspendListing }

    var stagedBodyExisted: Bool { lock.withLock { stagedFileExisted } }
    var uploadedBody: Data? { lock.withLock { sentBody } }

    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay {
        if suspendListing {
            await suspend()
            throw URLError(.networkConnectionLost)
        }
        return IngestProtocolV3.SegmentsDay(total: 0, items: [])
    }

    func prepareUpload(serverURL: String, day: String, segment: String, mediaFiles: [URL],
                       metadata: [String: IngestJSONValue]?, source: String?, boundary: String,
                       bodyURL: URL, ioInjector: BrowserIntakeIOInjector) throws -> PreparedIngestV3Upload {
        try IngestV3UploadRequestBuilder.build(baseURL: serverURL, day: day, segment: segment,
            selectedFiles: mediaFiles, meta: metadata, source: source, boundary: boundary, bodyURL: bodyURL,
            ioHooks: .browser(using: ioInjector))
    }

    func uploadStaged(prepared: PreparedIngestV3Upload, lease: BrowserUploadLease) async -> UploadResult {
        lock.withLock { stagedFileExisted = FileManager.default.fileExists(atPath: prepared.bodyURL.path) }
        await suspend()
        return .failure(URLError(.networkConnectionLost))
    }

    private func suspend() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                suspended = true
                if released { continuation.resume() }
                else { self.continuation = continuation }
            }
        }
    }

    func waitUntilSuspended(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !lock.withLock({ suspended }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { suspended }
    }

    func resume() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        pending?.resume()
    }
}

#endif
