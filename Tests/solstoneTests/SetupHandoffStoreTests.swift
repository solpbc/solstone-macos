// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import Testing
import SolstoneCore
@testable import solstone

@Suite("Setup handoff store")
struct SetupHandoffStoreTests {
    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: "/var/tmp").appendingPathComponent("setup-handoff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let sampleFingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func writePending(_ id: UUID, in dir: URL) throws {
        let handoff = SetupHandoff(handoffID: id, stepIndex: 5, journalRootPath: "/test/root",
                                   expectedInstanceID: "test-home", expectedCAFingerprint: sampleFingerprint)
        try JSONEncoder().encode(handoff).write(to: dir.appendingPathComponent("solstone-setup-handoff.json"))
    }

    @Test func terminalRefusalSurvivesNewResponsesAndChangedPairing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = UUID()
        let store = SetupMailboxStore(directory: dir)
        for id in [first, UUID(), UUID()] {
            try writePending(id, in: dir)
            #expect(try store.commitStep5(loadedID: id, alreadyAccepted: false,
                pairingBlocksNewAcceptance: true, refusalReason: .heldPairing,
                storeProgress: { Issue.record("must preserve existing setup") }) == .rejected(.heldPairing))
            #expect(try store.readStep5Refusal()?.handoffID == id)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("solstone-setup-handoff.json").path))
            #expect(try store.readStep5Receipt() == nil)
        }
        try writePending(first, in: dir)
        let rebuilt = SetupMailboxStore(directory: dir)
        #expect(try rebuilt.commitStep5(loadedID: first, alreadyAccepted: false,
            pairingBlocksNewAcceptance: false,
            storeProgress: { Issue.record("a refused ID must never become accepted") }) == .rejected(.heldPairing))
        #expect(try rebuilt.readStep5Refusal()?.handoffID == first)
    }

    @Test(arguments: ["solstone-setup-handoff-refusals.json", "solstone-setup-handoff-refused.json"])
    func refusalWriteFailuresKeepDecisionOrdering(failingName: String) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try writePending(id, in: dir)
        let store = SetupMailboxStore(directory: dir, replace: { data, url in
            if url.lastPathComponent == failingName { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        })
        #expect(throws: (any Error).self) {
            try store.commitStep5(loadedID: id, alreadyAccepted: false,
                pairingBlocksNewAcceptance: true, refusalReason: .heldPairing, storeProgress: {})
        }
        #expect(try store.readStep5Refusal() == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("solstone-setup-handoff.json").path))
        let rebuilt = SetupMailboxStore(directory: dir)
        let decisionWasPersisted = failingName == "solstone-setup-handoff-refused.json"
        let result = try rebuilt.commitStep5(loadedID: id, alreadyAccepted: false,
            pairingBlocksNewAcceptance: false, storeProgress: {})
        #expect(result == (decisionWasPersisted ? .rejected(.heldPairing) : .accepted))
    }

    @Test func cleanupFailureStillLeavesTerminalDecision() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try writePending(id, in: dir)
        let store = SetupMailboxStore(directory: dir, replace: { try $0.write(to: $1, options: .atomic) },
            remove: { _ in throw CocoaError(.fileWriteUnknown) })
        #expect(try store.commitStep5(loadedID: id, alreadyAccepted: false,
            pairingBlocksNewAcceptance: true, refusalReason: .continuationInProgress,
            storeProgress: {}) == .rejected(.continuationInProgress))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("solstone-setup-handoff.json").path))
        #expect(try SetupMailboxStore(directory: dir).commitStep5(loadedID: id,
            alreadyAccepted: false, pairingBlocksNewAcceptance: false,
            storeProgress: { Issue.record("terminal decision lost after failed cleanup") }) == .rejected(.continuationInProgress))
    }

    @Test(arguments: ["broken", "{\"schema\":\"future\",\"reasons\":{}}"])
    func invalidHistoryFailsClosedButTrustedAcceptanceCanRepublish(contents: String) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try writePending(id, in: dir)
        let history = dir.appendingPathComponent("solstone-setup-handoff-refusals.json")
        try Data(contents.utf8).write(to: history)
        let store = SetupMailboxStore(directory: dir)
        #expect(throws: (any Error).self) {
            try store.commitStep5(loadedID: id, alreadyAccepted: false,
                pairingBlocksNewAcceptance: false, storeProgress: { Issue.record("history read failure must block acceptance") })
        }
        #expect(try Data(contentsOf: history) == Data(contents.utf8))
        #expect(try store.readStep5Refusal() == nil)
        #expect(try store.commitStep5(loadedID: id, alreadyAccepted: true,
            pairingBlocksNewAcceptance: true, refusalReason: .heldPairing,
            storeProgress: { Issue.record("already accepted") }) == .republished)
        #expect(try store.readStep5Receipt()?.handoffID == id)
    }

    @Test func supersededRefusalCannotConsumeReplacement() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)
        let replacement = UUID()
        try writePending(replacement, in: dir)
        #expect(try store.commitStep5(loadedID: UUID(), alreadyAccepted: false,
            pairingBlocksNewAcceptance: true, refusalReason: .heldPairing,
            storeProgress: {}) == .rejected(.superseded))
        #expect(try store.readStep5Refusal() == nil)
        guard case .ready(let pending) = store.loadStep5() else { Issue.record("replacement was lost"); return }
        #expect(pending.handoffID == replacement)
    }

    @Test(arguments: ["broken", "schema", "reason", "stepIndex"])
    func unknownRefusalsAreNotOutcomes(field: String) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)
        #expect(try store.readStep5Refusal() == nil)
        let encoded = try JSONEncoder().encode(SetupHandoffRefusal(handoffID: UUID(), reason: .heldPairing))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        if field == "stepIndex" { object[field] = 1 } else { object[field] = "unknown" }
        let data = field == "broken" ? Data("broken".utf8) : try JSONSerialization.data(withJSONObject: object)
        try data.write(to: dir.appendingPathComponent("solstone-setup-handoff-refused.json"))
        #expect(try store.readStep5Refusal() == nil)
    }

    @Test func step1RoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SetupMailboxStore(directory: dir)
        let handoffID = UUID()

        #expect(try store.readStep1Receipt() == nil)

        try store.writeStep1(handoffID: handoffID)

        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        #expect(FileManager.default.fileExists(atPath: step1File.path))

        let data = try Data(contentsOf: step1File)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(jsonObject["schema"] as? String == "solstone.setup-handoff.v1")
        #expect(jsonObject["handoffID"] as? String == handoffID.uuidString.lowercased())
        #expect(jsonObject["stepIndex"] as? Int == 1)
        #expect(jsonObject["journalRootPath"] == nil)
        #expect(jsonObject["expectedInstanceID"] == nil)
        #expect(jsonObject["expectedCAFingerprint"] == nil)

        let decoded = try JSONDecoder().decode(SetupHandoff.self, from: data)
        #expect(decoded.handoffID == handoffID)
        #expect(decoded.stepIndex == 1)
        #expect(decoded.schema == SetupHandoff.schemaV1)

        // Receipt absent initially
        #expect(try store.readStep1Receipt() == nil)

        // Write step1 receipt
        let receipt = SetupHandoffReceipt(handoffID: handoffID, stepIndex: 1)
        let receiptData = try JSONEncoder().encode(receipt)
        try receiptData.write(to: dir.appendingPathComponent("journal-setup-handoff-accepted.json"))

        let readReceipt = try #require(try store.readStep1Receipt())
        #expect(readReceipt.handoffID == handoffID)
        #expect(readReceipt.stepIndex == 1)
        #expect(readReceipt == receipt)
    }

    @Test func receiptWithDifferentIDDoesNotMatch() throws {
        let id1 = UUID()
        let id2 = UUID()
        let receipt1 = SetupHandoffReceipt(handoffID: id1, stepIndex: 1)
        let receipt2 = SetupHandoffReceipt(handoffID: id2, stepIndex: 1)
        #expect(receipt1 != receipt2)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        // Receipt with stepIndex 5 should not be returned by readStep1Receipt
        let receiptStep5 = SetupHandoffReceipt(handoffID: id1, stepIndex: 5)
        let receiptData = try JSONEncoder().encode(receiptStep5)
        try receiptData.write(to: dir.appendingPathComponent("journal-setup-handoff-accepted.json"))
        #expect(try store.readStep1Receipt() == nil)
    }

    @Test func malformedStep5LeavesFileAndWritesNoReceipt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let receiptFile = dir.appendingPathComponent("solstone-setup-handoff-accepted.json")

        try Data("not valid json".utf8).write(to: step5File)
        #expect(store.loadStep5() == .malformed)

        let progressCalled = OSAllocatedUnfairLock(initialState: false)
        let result = try store.commitStep5(
            loadedID: UUID(),
            alreadyAccepted: false,
            pairingBlocksNewAcceptance: false,
            storeProgress: { progressCalled.withLock { $0 = true } }
        )

        #expect(result == .rejected(.malformed))
        #expect(!progressCalled.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: step5File.path))
        #expect(!FileManager.default.fileExists(atPath: receiptFile.path))
    }

    @Test func nonLowercaseOrShortFingerprintOrRelativeRootIsMalformed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)
        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let receiptFile = dir.appendingPathComponent("solstone-setup-handoff-accepted.json")

        // 1. Uppercase fingerprint
        let upperHandoff = SetupHandoff(
            handoffID: UUID(),
            stepIndex: 5,
            journalRootPath: "/valid/path",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint.uppercased()
        )
        #expect(!upperHandoff.isValidStep5Payload)
        try JSONEncoder().encode(upperHandoff).write(to: step5File)
        #expect(store.loadStep5() == .malformed)

        var result = try store.commitStep5(
            loadedID: upperHandoff.handoffID,
            alreadyAccepted: false,
            pairingBlocksNewAcceptance: false,
            storeProgress: {}
        )
        #expect(result == .rejected(.malformed))
        #expect(FileManager.default.fileExists(atPath: step5File.path))
        #expect(!FileManager.default.fileExists(atPath: receiptFile.path))

        // 2. Short fingerprint (63 chars)
        let shortFingerprint = String(sampleFingerprint.prefix(63))
        let shortHandoff = SetupHandoff(
            handoffID: UUID(),
            stepIndex: 5,
            journalRootPath: "/valid/path",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: shortFingerprint
        )
        #expect(!shortHandoff.isValidStep5Payload)
        try JSONEncoder().encode(shortHandoff).write(to: step5File)
        #expect(store.loadStep5() == .malformed)

        result = try store.commitStep5(
            loadedID: shortHandoff.handoffID,
            alreadyAccepted: false,
            pairingBlocksNewAcceptance: false,
            storeProgress: {}
        )
        #expect(result == .rejected(.malformed))

        // 3. Relative root
        let relativeHandoff = SetupHandoff(
            handoffID: UUID(),
            stepIndex: 5,
            journalRootPath: "relative/path",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        #expect(!relativeHandoff.isValidStep5Payload)
        try JSONEncoder().encode(relativeHandoff).write(to: step5File)
        #expect(store.loadStep5() == .malformed)

        result = try store.commitStep5(
            loadedID: relativeHandoff.handoffID,
            alreadyAccepted: false,
            pairingBlocksNewAcceptance: false,
            storeProgress: {}
        )
        #expect(result == .rejected(.malformed))
        #expect(!FileManager.default.fileExists(atPath: receiptFile.path))
    }

    @Test func lockTimeoutLeavesStep5FileAndOtherMailboxUnchanged() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let legacyHandoff = dir.appendingPathComponent("journal-handoff.json")
        let otherMailbox = dir.appendingPathComponent("journal-setup-handoff.json")

        let handoffID = UUID()
        let step5 = SetupHandoff(
            handoffID: handoffID,
            stepIndex: 5,
            journalRootPath: "/test/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        let step5Data = try JSONEncoder().encode(step5)
        try step5Data.write(to: step5File)
        try Data("legacy".utf8).write(to: legacyHandoff)
        try Data("step1".utf8).write(to: otherMailbox)

        let lockURL = dir.appendingPathComponent("solstone-setup-handoff.lock")
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        #expect(lockFD >= 0)
        #expect(flock(lockFD, LOCK_EX | LOCK_NB) == 0)

        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }

        let progressCalled = OSAllocatedUnfairLock(initialState: false)
        let result = try store.commitStep5(
            loadedID: handoffID,
            alreadyAccepted: false,
            pairingBlocksNewAcceptance: false,
            storeProgress: { progressCalled.withLock { $0 = true } }
        )

        #expect(result == .lockTimeout)
        #expect(!progressCalled.withLock { $0 })
        #expect(try Data(contentsOf: step5File) == step5Data)
        #expect(try Data(contentsOf: legacyHandoff) == Data("legacy".utf8))
        #expect(try Data(contentsOf: otherMailbox) == Data("step1".utf8))
    }

    @Test func h1LoadedThenFileReplacedByH2ReturnsSupersededAndLeavesH2WithNoH1Receipt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let receiptFile = dir.appendingPathComponent("solstone-setup-handoff-accepted.json")

        let id1 = UUID()
        let id2 = UUID()

        let h1 = SetupHandoff(
            handoffID: id1,
            stepIndex: 5,
            journalRootPath: "/test/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(h1).write(to: step5File)

        let loaded = store.loadStep5()
        guard case .ready(let loadedHandoff) = loaded else {
            Issue.record("Expected ready load")
            return
        }
        #expect(loadedHandoff.handoffID == id1)

        // File replaced by H2
        let h2 = SetupHandoff(
            handoffID: id2,
            stepIndex: 5,
            journalRootPath: "/test/root-2",
            expectedInstanceID: "inst-2",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(h2).write(to: step5File)

        let progressCalled = OSAllocatedUnfairLock(initialState: false)
        let result = try store.commitStep5(
            loadedID: id1,
            alreadyAccepted: false,
            pairingBlocksNewAcceptance: false,
            storeProgress: { progressCalled.withLock { $0 = true } }
        )

        #expect(result == .rejected(.superseded))
        #expect(!progressCalled.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: step5File.path))

        // Check file on disk is still H2
        let diskHandoff = try JSONDecoder().decode(SetupHandoff.self, from: Data(contentsOf: step5File))
        #expect(diskHandoff.handoffID == id2)

        // No receipt for H1 written
        #expect(!FileManager.default.fileExists(atPath: receiptFile.path))
    }

    @Test func alreadyAcceptedRepublishesReceiptDoesNotCallStoreProgressAndConsumesOnlyMatchingID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let receiptFile = dir.appendingPathComponent("solstone-setup-handoff-accepted.json")

        let id1 = UUID()
        let h1 = SetupHandoff(
            handoffID: id1,
            stepIndex: 5,
            journalRootPath: "/test/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(h1).write(to: step5File)

        let progressCalled = OSAllocatedUnfairLock(initialState: false)
        let result = try store.commitStep5(
            loadedID: id1,
            alreadyAccepted: true,
            pairingBlocksNewAcceptance: false,
            storeProgress: { progressCalled.withLock { $0 = true } }
        )

        #expect(result == .republished)
        #expect(!progressCalled.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: step5File.path))
        #expect(FileManager.default.fileExists(atPath: receiptFile.path))

        let receipt = try JSONDecoder().decode(SetupHandoffReceipt.self, from: Data(contentsOf: receiptFile))
        #expect(receipt.handoffID == id1)
        #expect(receipt.stepIndex == 5)

        // If file contains H2, alreadyAccepted with id1 does NOT consume H2
        let id2 = UUID()
        let h2 = SetupHandoff(
            handoffID: id2,
            stepIndex: 5,
            journalRootPath: "/test/root-2",
            expectedInstanceID: "inst-2",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(h2).write(to: step5File)

        let result2 = try store.commitStep5(
            loadedID: id1,
            alreadyAccepted: true,
            pairingBlocksNewAcceptance: false,
            storeProgress: { progressCalled.withLock { $0 = true } }
        )
        #expect(result2 == .rejected(.superseded))
        #expect(!progressCalled.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: step5File.path))
    }

    @Test func missingFilePlusAlreadyAcceptedRepublishes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let receiptFile = dir.appendingPathComponent("solstone-setup-handoff-accepted.json")

        #expect(!FileManager.default.fileExists(atPath: step5File.path))

        let id = UUID()
        let progressCalled = OSAllocatedUnfairLock(initialState: false)
        let result = try store.commitStep5(
            loadedID: id,
            alreadyAccepted: true,
            pairingBlocksNewAcceptance: false,
            storeProgress: { progressCalled.withLock { $0 = true } }
        )

        #expect(result == .republished)
        #expect(!progressCalled.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: receiptFile.path))

        let receipt = try JSONDecoder().decode(SetupHandoffReceipt.self, from: Data(contentsOf: receiptFile))
        #expect(receipt.handoffID == id)
        #expect(receipt.stepIndex == 5)
    }

    @Test func storeProgressThrowWritesNoReceipt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let receiptFile = dir.appendingPathComponent("solstone-setup-handoff-accepted.json")

        let id = UUID()
        let h1 = SetupHandoff(
            handoffID: id,
            stepIndex: 5,
            journalRootPath: "/test/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(h1).write(to: step5File)

        struct ProgressError: Error {}

        #expect(throws: ProgressError.self) {
            try store.commitStep5(
                loadedID: id,
                alreadyAccepted: false,
                pairingBlocksNewAcceptance: false,
                storeProgress: { throw ProgressError() }
            )
        }

        #expect(FileManager.default.fileExists(atPath: step5File.path))
        #expect(!FileManager.default.fileExists(atPath: receiptFile.path))
    }

    @Test func heldPairingRejectsNewAcceptance() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let receiptFile = dir.appendingPathComponent("solstone-setup-handoff-accepted.json")

        let id = UUID()
        let h1 = SetupHandoff(
            handoffID: id,
            stepIndex: 5,
            journalRootPath: "/test/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(h1).write(to: step5File)

        let progressCalled = OSAllocatedUnfairLock(initialState: false)
        let result = try store.commitStep5(
            loadedID: id,
            alreadyAccepted: false,
            pairingBlocksNewAcceptance: true,
            storeProgress: { progressCalled.withLock { $0 = true } }
        )

        #expect(result == .rejected(.heldPairing))
        #expect(!progressCalled.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: step5File.path))
        #expect(!FileManager.default.fileExists(atPath: receiptFile.path))
    }

    private func caseReadyID(_ load: SetupStep1Load) -> UUID? {
        if case .ready(let h) = load { return h.handoffID } else { return nil }
    }

    @Test func reciprocalOperationsRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        // Capture writes Step 1
        let step1ID = UUID()
        try store.writeStep1(handoffID: step1ID)

        // Journal loads Step 1
        let step1Load = store.loadStep1()
        guard case .ready(let step1Handoff) = step1Load else {
            Issue.record("Expected ready step1 load")
            return
        }
        #expect(step1Handoff.handoffID == step1ID)
        #expect(step1Handoff.stepIndex == 1)

        // Journal commits Step 1
        final class ProgressFlag: @unchecked Sendable {
            var value = false
        }
        let journalProgress = ProgressFlag()
        let step1Commit = try store.commitStep1(loadedID: step1ID, alreadyAccepted: false, refuseNewAcceptance: false) {
            journalProgress.value = true
        }
        #expect(step1Commit == .accepted)
        #expect(journalProgress.value)

        // Capture reads Step 1 receipt
        let step1Receipt = try #require(try store.readStep1Receipt())
        #expect(step1Receipt.handoffID == step1ID)
        #expect(step1Receipt.stepIndex == 1)

        // Journal writes Step 5
        let step5ID = UUID()
        let step5Handoff = SetupHandoff(
            handoffID: step5ID,
            stepIndex: 5,
            journalRootPath: "/test/journal/root",
            expectedInstanceID: "inst-123",
            expectedCAFingerprint: sampleFingerprint
        )
        try store.writeStep5(step5Handoff)

        // Capture loads Step 5
        let step5Load = store.loadStep5()
        guard case .ready(let step5Loaded) = step5Load else {
            Issue.record("Expected ready step5 load")
            return
        }
        #expect(step5Loaded.handoffID == step5ID)
        #expect(step5Loaded.stepIndex == 5)
        #expect(step5Loaded.expectedInstanceID == "inst-123")

        // Capture commits Step 5
        let captureProgress = ProgressFlag()
        let step5Commit = try store.commitStep5(
            loadedID: step5ID,
            alreadyAccepted: false,
            pairingBlocksNewAcceptance: false
        ) {
            captureProgress.value = true
        }
        #expect(step5Commit == .accepted)
        #expect(captureProgress.value)

        // Journal reads Step 5 receipt
        let step5Receipt = try #require(try store.readStep5Receipt())
        #expect(step5Receipt.handoffID == step5ID)
        #expect(step5Receipt.stepIndex == 5)
    }

    @Test func step1H1ReplacedByH2ThenCommitH1LeavesH2AndWritesNoH1Receipt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)

        let id1 = UUID()
        let id2 = UUID()

        try store.writeStep1(handoffID: id1)
        #expect(caseReadyID(store.loadStep1()) == id1)

        // Replace with H2
        try store.writeStep1(handoffID: id2)

        final class ProgressFlag: @unchecked Sendable {
            var value = false
        }
        let progressFlag = ProgressFlag()
        let commitResult = try store.commitStep1(loadedID: id1, alreadyAccepted: false, refuseNewAcceptance: false) {
            progressFlag.value = true
        }

        #expect(commitResult == .rejected(SetupHandoffRejection.superseded))
        #expect(!progressFlag.value)
        #expect(try store.readStep1Receipt() == nil)
        #expect(caseReadyID(store.loadStep1()) == id2)
    }

    @Test func writeStep5RejectsInvalidPayloadAndDoesNotCreateFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)
        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")

        // Invalid: uppercase fingerprint
        let upperHandoff = SetupHandoff(
            handoffID: UUID(),
            stepIndex: 5,
            journalRootPath: "/test/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint.uppercased()
        )
        #expect(throws: SetupMailboxError.self) {
            try store.writeStep5(upperHandoff)
        }
        #expect(!FileManager.default.fileExists(atPath: step5File.path))

        // Invalid: relative path
        let relativeHandoff = SetupHandoff(
            handoffID: UUID(),
            stepIndex: 5,
            journalRootPath: "relative/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        #expect(throws: SetupMailboxError.self) {
            try store.writeStep5(relativeHandoff)
        }
        #expect(!FileManager.default.fileExists(atPath: step5File.path))
    }

    @Test func tornSnapshotWithOnlyIDStringIsNotAlreadyAcceptedAndThrowLeavesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)
        let continuationStore = SetupContinuationStore(directory: dir)

        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let receiptFile = dir.appendingPathComponent("solstone-setup-handoff-accepted.json")

        let id = UUID()
        let h1 = SetupHandoff(
            handoffID: id,
            stepIndex: 5,
            journalRootPath: "/test/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(h1).write(to: step5File)

        // No accepted snapshot in continuation
        #expect(continuationStore.load()?.accepted == nil)
        let alreadyAccepted = continuationStore.load()?.accepted?.handoffID == id
        #expect(!alreadyAccepted)

        // Commit fails because record throws
        struct TestStorageError: Error {}
        #expect(throws: TestStorageError.self) {
            try store.commitStep5(
                loadedID: id,
                alreadyAccepted: alreadyAccepted,
                pairingBlocksNewAcceptance: false,
                storeProgress: { throw TestStorageError() }
            )
        }

        #expect(FileManager.default.fileExists(atPath: step5File.path))
        #expect(!FileManager.default.fileExists(atPath: receiptFile.path))

        // Now record a complete snapshot
        let snapshot = SetupAcceptedStep5Snapshot(
            handoffID: id,
            journalRootPath: "/test/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        try continuationStore.save(SetupContinuation(phase: .connection, accepted: snapshot, mode: .supporting))
        #expect(continuationStore.load()?.accepted?.handoffID == id)

        // Committing with complete snapshot republishes receipt and consumes file
        let republishResult = try store.commitStep5(
            loadedID: id,
            alreadyAccepted: continuationStore.load()?.accepted?.handoffID == id,
            pairingBlocksNewAcceptance: false,
            storeProgress: { fatalError("Should not be called") }
        )
        #expect(republishResult == .republished)
        #expect(!FileManager.default.fileExists(atPath: step5File.path))
        #expect(FileManager.default.fileExists(atPath: receiptFile.path))
    }

    @Test func h2DuringMicrophoneWithCompleteH1SnapshotRejectsContinuationInProgress() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupMailboxStore(directory: dir)
        let continuationStore = SetupContinuationStore(directory: dir)

        let step5File = dir.appendingPathComponent("solstone-setup-handoff.json")
        let receiptFile = dir.appendingPathComponent("solstone-setup-handoff-accepted.json")

        let h1ID = UUID()
        let h1Snapshot = SetupAcceptedStep5Snapshot(
            handoffID: h1ID,
            journalRootPath: "/test/root-1",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        try continuationStore.save(SetupContinuation(phase: .microphone, accepted: h1Snapshot, mode: .supporting))

        // New H2 arrives on disk
        let h2ID = UUID()
        let h2 = SetupHandoff(
            handoffID: h2ID,
            stepIndex: 5,
            journalRootPath: "/test/root-2",
            expectedInstanceID: "inst-2",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(h2).write(to: step5File)

        let result = try store.commitStep5(
            loadedID: h2ID,
            alreadyAccepted: continuationStore.load()?.accepted?.handoffID == h2ID,
            pairingBlocksNewAcceptance: false,
            storeProgress: {
                if continuationStore.load()?.phase == .microphone {
                    throw SetupMailboxError.continuationInProgress
                }
            }
        )

        #expect(result == .rejected(.continuationInProgress))
        #expect(FileManager.default.fileExists(atPath: step5File.path))
        #expect(!FileManager.default.fileExists(atPath: receiptFile.path))
        let currentCont = continuationStore.load()
        #expect(currentCont?.phase == .microphone)
        #expect(currentCont?.accepted?.handoffID == h1ID)
    }
}
