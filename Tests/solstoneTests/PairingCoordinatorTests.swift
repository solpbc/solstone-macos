// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import SPLTunnel
import Testing
@testable import solstone

@Suite("PairingCoordinator")
@MainActor
struct PairingCoordinatorTests {
    @Test func pairSuccessSavesPairingAndReactivatesOwner() async throws {
        let saved = pairing(instanceID: "11111111-1111-1111-1111-111111111111")
        let store = PairingStore(pairing: nil)
        let script = PairScript([.success(saved)])
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(store: store, script: script, reactivate: reactivate)

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))

        #expect(coordinator.state == .paired)
        #expect(store.currentPairing == saved)
        #expect(store.savedPairings == [saved])
        #expect(await script.callCount == 1)
        #expect(await reactivate.count == 1)
        let calls = await script.calls
        let call = try #require(calls.first)
        #expect(call.deviceLabel == "test mac")
        #expect(call.relayEndpoint.absoluteString == "https://relay.test")
    }

    @Test func enrollUnavailablePairingStillSavesAndPairs() async throws {
        let saved = pairing(
            instanceID: "11111111-1111-1111-1111-111111111111",
            relayEnrollment: .unavailable
        )
        let store = PairingStore(pairing: nil)
        let coordinator = makeCoordinator(store: store, outcomes: [.success(saved)])

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))

        #expect(coordinator.state == .paired)
        #expect(store.currentPairing == saved)
        #expect(store.savedPairings == [saved])
    }

    @Test func saveThrowsSetsSaveFailedAndDoesNotReactivate() async throws {
        let saved = pairing(instanceID: "11111111-1111-1111-1111-111111111111")
        let store = PairingStore(pairing: nil, saveError: PairScriptError.saveFailed)
        let script = PairScript([.success(saved)])
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(store: store, script: script, reactivate: reactivate)

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))

        #expect(coordinator.state == .saveFailed)
        #expect(store.currentPairing == nil)
        #expect(store.saveCount == 1)
        #expect(await script.callCount == 1)
        #expect(await reactivate.count == 0)
    }

    // Acceptance 4: Same-journal re-pair (direct cert pin and relay SPKI pin) with matching cert second in chain.
    @Test func sameJournalDirectCertPinRunsCeremonyRetiresOldSavesAndSetsAlreadyConnected() async throws {
        let multiCertCA = otherCACertPEM + "\n" + testCACertPEM
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: multiCertCA)
        let refreshed = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: multiCertCA)
        let order = OrderRecorder()
        let store = PairingStore(pairing: prior)
        let script = PairScript([.success(refreshed)], onPair: {
            order.record("pair")
        })
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(
            store: store,
            script: script,
            reactivate: reactivate,
            onSave: {
                order.record("save")
            },
            retireOwnCredential: { _, _ in
                order.record("retire")
                return true
            }
        )

        let link = try directPairLink(caPEM: testCACertPEM)
        await coordinator.submitPairingLink(link)

        #expect(coordinator.state == .alreadyConnected)
        #expect(store.currentPairing == refreshed)
        #expect(await script.callCount == 1)
        #expect(store.saveCount == 1)
        #expect(await reactivate.count == 1)
        #expect(order.events == ["pair", "retire"])
        #expect(store.saveCount == 1)
        #expect(try store.loadCarriedPairingRecord().replacementOfferID == nil)
    }

    @Test func sameJournalRelaySPKIPinRunsCeremonyRetiresOldSavesAndSetsAlreadyConnected() async throws {
        let multiCertCA = otherCACertPEM + "\n" + testCACertPEM
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: multiCertCA)
        let refreshed = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: multiCertCA)
        let order = OrderRecorder()
        let store = PairingStore(pairing: prior)
        let script = PairScript([.success(refreshed)], onPair: {
            order.record("pair")
        })
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(
            store: store,
            script: script,
            reactivate: reactivate,
            onSave: {
                order.record("save")
            },
            retireOwnCredential: { _, _ in
                order.record("retire")
                return true
            }
        )

        let link = try relayPairLink(caPEM: testCACertPEM)
        await coordinator.submitPairingLink(link)

        #expect(coordinator.state == .alreadyConnected)
        #expect(store.currentPairing == refreshed)
        #expect(await script.callCount == 1)
        #expect(store.saveCount == 1)
        #expect(await reactivate.count == 1)
        #expect(order.events == ["pair", "retire"])
        #expect(store.saveCount == 1)
    }

    // Acceptance 5: Different journal does not call pair on submit and sets .switchConfirmPending.
    @Test func differentJournalRequiresSwitchConfirmBeforeCeremonyOrOverwrite() async throws {
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: testCACertPEM)
        let replacement = pairing(instanceID: "22222222-2222-2222-2222-222222222222", caChainPEM: otherCACertPEM)
        let store = PairingStore(pairing: prior)
        let script = PairScript([.success(replacement)])
        let coordinator = makeCoordinator(store: store, script: script)

        let link = try relayPairLink(caPEM: otherCACertPEM)
        await coordinator.submitPairingLink(link)

        #expect(coordinator.state == .switchConfirmPending)
        #expect(store.currentPairing == prior)
        #expect(store.saveCount == 0)
        #expect(await script.callCount == 0)
    }

    // Acceptance 6: Cancel switch drops pending link without ceremony or retire.
    @Test func cancelSwitchRestoresIdleWithoutCeremonyOrRetire() async throws {
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: testCACertPEM)
        let replacement = pairing(instanceID: "22222222-2222-2222-2222-222222222222", caChainPEM: otherCACertPEM)
        let store = PairingStore(pairing: prior)
        let script = PairScript([.success(replacement)])
        let order = OrderRecorder()
        let coordinator = makeCoordinator(
            store: store,
            script: script,
            retireOwnCredential: { _, _ in
                order.record("retire")
                return true
            }
        )

        let link = try relayPairLink(caPEM: otherCACertPEM)
        await coordinator.submitPairingLink(link)
        #expect(coordinator.state == .switchConfirmPending)

        coordinator.cancelSwitch()
        #expect(coordinator.state == .idle)
        #expect(await script.callCount == 0)
        #expect(store.currentPairing == prior)
        #expect(store.saveCount == 0)
        #expect(order.events.isEmpty)
    }

    // Acceptance 7: Confirmed switch runs ceremony, retires old, saves new, sets .switched.
    @Test func confirmSwitchRunsCeremonyRetiresOldSavesAndSetsSwitched() async throws {
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: testCACertPEM)
        let replacement = pairing(instanceID: "22222222-2222-2222-2222-222222222222", caChainPEM: otherCACertPEM)
        let order = OrderRecorder()
        let store = PairingStore(pairing: prior)
        let script = PairScript([.success(replacement)], onPair: {
            order.record("pair")
        })
        let reactivate = ReactivateRecorder()
        let clear = ClearRecorder()
        let coordinator = makeCoordinator(
            store: store,
            script: script,
            reactivate: reactivate,
            clear: clear,
            onSave: {
                order.record("save")
            },
            retireOwnCredential: { old, _ in
                #expect(old == prior)
                order.record("retire")
                return true
            }
        )

        let link = try relayPairLink(caPEM: otherCACertPEM)
        await coordinator.submitPairingLink(link)
        #expect(coordinator.state == .switchConfirmPending)
        #expect(await script.callCount == 0)

        await coordinator.confirmSwitch()

        #expect(coordinator.state == .switched)
        #expect(store.currentPairing == replacement)
        #expect(store.savedPairings == [replacement])
        #expect(await script.callCount == 1)
        #expect(await reactivate.count == 1)
        #expect(clear.count == 1)
        #expect(order.events == ["pair", "retire"])
        #expect(store.saveCount == 1)
    }

    // Acceptance 8: Different journal ceremony failure on confirm preserves prior pairing.
    @Test func differentJournalCeremonyFailureOnConfirmPreservesPriorPairing() async throws {
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: testCACertPEM)
        let store = PairingStore(pairing: prior)
        let script = PairScript([.failure(PairError.nonceExpired)])
        let reactivate = ReactivateRecorder()
        let order = OrderRecorder()
        let coordinator = makeCoordinator(
            store: store,
            script: script,
            reactivate: reactivate,
            retireOwnCredential: { _, _ in
                order.record("retire")
                return true
            }
        )

        let link = try relayPairLink(caPEM: otherCACertPEM)
        await coordinator.submitPairingLink(link)

        #expect(coordinator.state == .switchConfirmPending)
        #expect(store.currentPairing == prior)
        #expect(store.saveCount == 0)
        #expect(await script.callCount == 0)

        await coordinator.confirmSwitch()

        #expect(coordinator.state == .failed(.staleLink))
        #expect(store.currentPairing == prior)
        #expect(store.saveCount == 0)
        #expect(await script.callCount == 1)
        #expect(await reactivate.count == 0)
        #expect(order.events.isEmpty)
    }

    @Test func directDifferentInstanceIDRequiresSwitchConfirmBeforeOverwrite() async throws {
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: testCACertPEM)
        let replacement = pairing(instanceID: "22222222-2222-2222-2222-222222222222", caChainPEM: otherCACertPEM)
        let store = PairingStore(pairing: prior)
        let script = PairScript([.success(replacement)])
        let reactivate = ReactivateRecorder()
        let clear = ClearRecorder()
        let coordinator = makeCoordinator(store: store, script: script, reactivate: reactivate, clear: clear)

        await coordinator.submitPairingLink(directPairLink)

        #expect(coordinator.state == .switchConfirmPending)
        #expect(store.currentPairing == prior)
        #expect(store.saveCount == 0)
        #expect(await reactivate.count == 0)
        #expect(clear.count == 0)
        #expect(await script.callCount == 0)

        await coordinator.confirmSwitch()

        #expect(coordinator.state == .switched)
        #expect(store.currentPairing == replacement)
        #expect(store.savedPairings == [replacement])
        #expect(store.saveCount == 1)
        #expect(await reactivate.count == 1)
        #expect(clear.count == 1)
        #expect(await script.callCount == 1)
    }

    // Acceptance 2: Unpair while retire stands in for connected owner.
    @Test func unpairRetiresBeforeDeleteAndEndsSelfRetirementAfterDelete() async throws {
        let testPairing = pairing()
        let order = OrderRecorder()
        let store = PairingStore(pairing: testPairing)
        let reactivate = ReactivateRecorder()
        let clear = ClearRecorder()
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [],
            reactivate: reactivate,
            clear: clear,
            retireOwnCredential: { pairing, _ in
                #expect(pairing == testPairing)
                order.record("retire")
                return true
            },
            endSelfRetirement: {
                #expect(store.deleted)
                order.record("endSelfRetirement")
            }
        )

        #expect(await coordinator.unpair())

        #expect(coordinator.state == .idle)
        #expect(store.currentPairing == nil)
        #expect(store.deleted)
        #expect(store.deleteCount == 1)
        #expect(await reactivate.count == 1)
        #expect(clear.count == 1)
        #expect(order.events == ["retire", "endSelfRetirement"])
    }

    // Acceptance 3: Unpair edge cases.
    @Test func unpairWhenLoadThrowsSkipsRetireDeletesAndEndsSelfRetirement() async throws {
        let order = OrderRecorder()
        let store = PairingStore(pairing: pairing(), loadError: PairScriptError.noOutcome)
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [],
            reactivate: reactivate,
            retireOwnCredential: { _, _ in
                order.record("retire")
                return true
            },
            endSelfRetirement: {
                #expect(store.deleted)
                order.record("endSelfRetirement")
            }
        )

        #expect(await coordinator.unpair())

        #expect(coordinator.state == .idle)
        #expect(store.deleted)
        #expect(await reactivate.count == 1)
        #expect(order.events == ["endSelfRetirement"])
    }

    @Test func unpairWhenLoadReturnsNilSkipsRetireDeletesAndEndsSelfRetirement() async throws {
        let order = OrderRecorder()
        let store = PairingStore(pairing: nil)
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [],
            retireOwnCredential: { _, _ in
                order.record("retire")
                return true
            },
            endSelfRetirement: {
                #expect(store.deleted)
                order.record("endSelfRetirement")
            }
        )

        #expect(await coordinator.unpair())

        #expect(coordinator.state == .idle)
        #expect(store.deleted)
        #expect(order.events == ["endSelfRetirement"])
    }

    @Test func unreachableJournalUnpairStillRemovesTheLocalPairingAfterDurableInvalidation() async throws {
        let order = OrderRecorder()
        let store = PairingStore(pairing: pairing())
        let reactivate = ReactivateRecorder()
        let clear = ClearRecorder()
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [],
            reactivate: reactivate,
            clear: clear,
            retireOwnCredential: { _, _ in
                #expect((try? store.loadCarriedPairingRecord())?.invalidation != nil)
                order.record("retire")
                return false
            },
            endSelfRetirement: {
                order.record("endSelfRetirement")
            }
        )

        #expect(await coordinator.unpair())

        #expect(coordinator.state == .idle)
        #expect(store.deleted)
        #expect(store.currentPairing == nil)
        #expect(try store.loadCarriedPairingRecord().invalidation == nil)
        #expect(await reactivate.count == 1)
        #expect(clear.count == 1)
        #expect(order.events == ["retire", "endSelfRetirement"])
    }

    @Test func unpairWhenDeleteThrowsFailsLocalSetupAndEndsSelfRetirementWithoutReactivate() async throws {
        let order = OrderRecorder()
        let store = PairingStore(pairing: pairing(), deleteError: PairScriptError.noOutcome)
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [],
            reactivate: reactivate,
            retireOwnCredential: { _, _ in
                order.record("retire")
                return true
            },
            endSelfRetirement: {
                order.record("endSelfRetirement")
            }
        )

        #expect(!(await coordinator.unpair()))

        #expect(coordinator.state == .failed(.localSetup))
        #expect(store.currentPairing != nil)
        #expect(!store.deleted)
        #expect(try store.loadCarriedPairingRecord().invalidation?.remoteRetirementConfirmed == true)
        #expect(await reactivate.count == 0)
        #expect(order.events == ["retire", "endSelfRetirement"])
    }

    @Test func invalidationPersistenceFailurePreservesPairingAndSendsNoRetirement() async throws {
        let prior = pairing()
        let store = PairingStore(pairing: prior, carriedRecordSaveError: PairScriptError.saveFailed)
        let retireCalls = LockedCounter()
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [],
            retireOwnCredential: { _, _ in retireCalls.increment(); return true }
        )

        #expect(!(await coordinator.unpair()))

        #expect(coordinator.state == .failed(.localSetup))
        #expect(store.currentPairing == prior)
        #expect(!store.deleted)
        #expect(store.deleteCount == 0)
        #expect(retireCalls.count == 0)
    }

    @Test func lostRetirementResponseRetriesSameDurableOperationAfterReopen() async throws {
        let prior = pairing()
        let store = PairingStore(pairing: prior)
        let firstOperation = LockedValue<String>()
        // The journal does not answer and the local delete is interrupted, so the
        // durable invalidation outlives the first attempt.
        store.setDeleteError(PairScriptError.noOutcome)
        let firstCoordinator = makeCoordinator(
            store: store,
            outcomes: [],
            retireOwnCredential: { _, operationID in
                firstOperation.set(operationID)
                return false
            }
        )

        #expect(!(await firstCoordinator.unpair()))
        let pending = try #require(store.loadCarriedPairingRecord().invalidation)
        #expect(pending.remoteRetirementAttempted)
        #expect(!pending.remoteRetirementConfirmed)
        #expect(store.currentPairing == prior)

        store.setDeleteError(nil)
        let retryOperation = LockedValue<String>()
        let reopened = makeCoordinator(
            store: store,
            outcomes: [],
            retireOwnCredential: { _, operationID in
                retryOperation.set(operationID)
                return true
            }
        )
        await reopened.recoverDurableInvalidation()

        #expect(retryOperation.current == firstOperation.current)
        #expect(store.deleted)
        #expect(store.currentPairing == nil)
        #expect(try store.loadCarriedPairingRecord().invalidation == nil)
    }

    @Test func persistedChoiceCannotSubmitOrReconcileAfterDurableInvalidation() async throws {
        let current = pairingWithFingerprint("sha256:" + String(repeating: "b", count: 64))
        let store = PairingStore(pairing: current)
        let credentials = PairingCredentialStore(store: store)
        _ = try credentials.load()
        let revision = PairingCredentialRevision(from: current)
        let decision = CarriedPairingDecision(
            decisionID: "123e4567-e89b-42d3-a456-426614174050",
            choice: .newDevice,
            replacesCID: nil,
            credentialFingerprint: current.fingerprint,
            credentialRevision: revision.revision
        )
        try credentials.saveCarriedPairingRecord(offeredRecord(with: decision))
        _ = try credentials.beginInvalidation(for: current, operationID: "decision-invalidated")
        let control = PairingControlScript(mode: .accepted, store: store)
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )
        coordinator.refreshPendingActions(markConfirmed: false)
        let initialState = coordinator.migrationDecisionState

        await coordinator.checkPendingMigrationDecision()

        #expect(control.events.isEmpty)
        #expect(coordinator.pendingMigrationDecision == decision)
        #expect(coordinator.migrationDecisionState == initialState)
        #expect(try credentials.carriedPairingRecord().decision == decision)
        #expect(try credentials.carriedPairingRecord().invalidation?.operationID == "decision-invalidated")
    }

    @Test func terminalDecisionMismatchKeepsTheDurableChoicePending() async throws {
        let current = pairingWithFingerprint("sha256:" + String(repeating: "b", count: 64))
        let store = PairingStore(pairing: current)
        let revision = PairingCredentialRevision(from: current)
        try store.saveCarriedPairingRecord(offeredRecord(with: CarriedPairingDecision(
            decisionID: "123e4567-e89b-42d3-a456-426614174010",
            choice: .newDevice,
            replacesCID: nil,
            credentialFingerprint: current.fingerprint,
            credentialRevision: revision.revision
        )))
        let control = PairingControlScript(mode: .mismatchedTerminal, store: store)
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        coordinator.refreshPendingActions(markConfirmed: false)
        await coordinator.checkPendingMigrationDecision()

        #expect(control.events == ["state", "decide"])
        #expect(coordinator.migrationDecisionState == "decision_unknown")
        #expect(coordinator.pendingMigrationDecision?.choice == .newDevice)
        #expect(try store.loadCarriedPairingRecord().decision?.choice == .newDevice)
    }

    @Test func lateDecisionCannotChangePresentationAfterUnpairAndSameJournalReplacement() async throws {
        let old = pairingWithFingerprint("sha256:" + String(repeating: "b", count: 64))
        let replacement = pairingWithFingerprint("sha256:" + String(repeating: "c", count: 64))
        let store = PairingStore(pairing: old)
        let revision = PairingCredentialRevision(from: old)
        try store.saveCarriedPairingRecord(offeredRecord(with: CarriedPairingDecision(
            decisionID: "123e4567-e89b-42d3-a456-426614174030",
            choice: .newDevice,
            replacesCID: nil,
            credentialFingerprint: old.fingerprint,
            credentialRevision: revision.revision
        )))
        let gate = OneShotContinuationGate()
        let control = PairingControlScript(mode: .accepted, store: store, decisionGate: gate)
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(replacement)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )
        coordinator.refreshPendingActions(markConfirmed: false)

        let choiceTask = Task { await coordinator.checkPendingMigrationDecision() }
        await control.waitUntilDecisionStarts()

        #expect(await coordinator.unpair())
        await coordinator.submitPairingLink(relayPairLink(instanceID: replacement.instanceID))
        let afterReplacementRecord = try store.loadCarriedPairingRecord()
        let pendingPresentation = coordinator.pendingMigrationDecision
        let decisionPresentation = coordinator.migrationDecisionState

        gate.release()
        await choiceTask.value

        let finalRecord = try store.loadCarriedPairingRecord()
        #expect(finalRecord.decision == afterReplacementRecord.decision)
        #expect(finalRecord.replacementOfferID == afterReplacementRecord.replacementOfferID)
        #expect(coordinator.pendingMigrationDecision == pendingPresentation)
        #expect(coordinator.migrationDecisionState == decisionPresentation)
    }

    @Test func lateDecisionCannotChangePresentationAfterConfirmedSwitch() async throws {
        let old = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: testCACertPEM)
        let replacement = pairing(instanceID: "22222222-2222-2222-2222-222222222222", caChainPEM: otherCACertPEM)
        let store = PairingStore(pairing: old)
        let revision = PairingCredentialRevision(from: old)
        try store.saveCarriedPairingRecord(offeredRecord(with: CarriedPairingDecision(
            decisionID: "123e4567-e89b-42d3-a456-426614174060",
            choice: .newDevice,
            replacesCID: nil,
            credentialFingerprint: old.fingerprint,
            credentialRevision: revision.revision
        )))
        let gate = OneShotContinuationGate()
        let control = PairingControlScript(mode: .accepted, store: store, decisionGate: gate)
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(replacement)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )
        coordinator.refreshPendingActions(markConfirmed: false)

        let decisionTask = Task { await coordinator.checkPendingMigrationDecision() }
        await control.waitUntilDecisionStarts()
        await coordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await coordinator.confirmSwitch()
        let replacedPairing = store.currentPairing
        let replacedRecord = try store.loadCarriedPairingRecord()
        let pendingPresentation = coordinator.pendingMigrationDecision
        let decisionPresentation = coordinator.migrationDecisionState

        gate.release()
        await decisionTask.value

        #expect(store.currentPairing == replacedPairing)
        #expect(try store.loadCarriedPairingRecord().decision == replacedRecord.decision)
        #expect(try store.loadCarriedPairingRecord().invalidation == replacedRecord.invalidation)
        #expect(coordinator.pendingMigrationDecision == pendingPresentation)
        #expect(coordinator.migrationDecisionState == decisionPresentation)
    }

    @Test func freshPairReplacementOfferIsDeferredAndDismissalSubmitsNothing() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let otherCID = "sha256:" + String(repeating: "c", count: 64)
        let saved = pairingWithFingerprint(selfCID)
        let store = PairingStore(pairing: nil)
        let control = PairingControlScript(
            mode: .accepted,
            store: store,
            clients: [
                CarriedPairingClientRow(cid: selfCID, displayLabel: "Laptop"),
                CarriedPairingClientRow(cid: otherCID, displayLabel: "Other")
            ]
        )
        let portHolder = LockedValue<Int>()
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(saved)],
            carriedPairingControl: control.client,
            localPort: { portHolder.current }
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        var record = try store.loadCarriedPairingRecord()
        #expect(record.replacementOfferID == nil)
        #expect(!record.replacementOfferShown)
        #expect(!coordinator.replacementOfferVisible)
        #expect(record.freshPairObligation == PairingCredentialRevision(from: saved))
        #expect(control.events.filter { $0 == "clients" }.isEmpty)

        _ = coordinator.refreshPendingActions(markConfirmed: false)
        #expect(!coordinator.replacementOfferVisible)
        #expect(control.events.filter { $0 == "clients" }.isEmpty)

        await coordinator.refreshPendingActions(markConfirmed: true).value
        #expect(!coordinator.replacementOfferVisible)
        #expect(control.events.filter { $0 == "clients" }.isEmpty)

        portHolder.set(7070)
        await coordinator.refreshPendingActions(markConfirmed: true).value
        #expect(coordinator.replacementOfferVisible)
        record = try store.loadCarriedPairingRecord()
        let offerID = try #require(record.replacementOfferID)
        #expect(!record.replacementOfferShown)
        #expect(record.freshPairObligation == nil)
        #expect(control.events.filter { $0 == "clients" }.count == 1)

        coordinator.dismissReplacementPicker()
        #expect(!(try store.loadCarriedPairingRecord().replacementOfferShown))
        _ = coordinator.refreshPendingActions(markConfirmed: true)
        #expect(coordinator.replacementOfferVisible)
        coordinator.markReplacementOfferShown()
        #expect(try store.loadCarriedPairingRecord().replacementOfferShown)

        coordinator.dismissReplacementPicker()
        #expect(!coordinator.replacementOfferVisible)
        #expect(control.events.filter { $0 == "decide" }.isEmpty)
        record = try store.loadCarriedPairingRecord()
        #expect(record.replacementOfferID == offerID)
        #expect(record.replacementOfferShown)
        #expect(record.decision == nil)

        _ = coordinator.refreshPendingActions(markConfirmed: true)
        #expect(!coordinator.replacementOfferVisible)
    }

    @Test func replacementPickerRequiresExplicitCurrentCIDAndVerifiedTerminalReply() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let firstCID = "sha256:" + String(repeating: "c", count: 64)
        let secondCID = "sha256:" + String(repeating: "d", count: 64)
        let saved = pairingWithFingerprint(selfCID)
        let store = PairingStore(pairing: nil)
        let control = PairingControlScript(
            mode: .accepted,
            store: store,
            clients: [
                CarriedPairingClientRow(cid: selfCID, displayLabel: "Laptop"),
                CarriedPairingClientRow(cid: firstCID, displayLabel: "Laptop"),
                CarriedPairingClientRow(cid: secondCID, displayLabel: "Laptop")
            ]
        )
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(saved)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        await coordinator.refreshPendingActions(markConfirmed: true).value
        coordinator.markReplacementOfferShown()
        await coordinator.openReplacementPicker()
        #expect(coordinator.replacementPickerVisible)
        #expect(coordinator.replacementTargets.map(\.cid) == [firstCID, secondCID])
        #expect(coordinator.replacementTargets.map(\.displayLabel) == ["Laptop", "Laptop"])
        #expect(coordinator.selectedReplacementCID == nil)

        await coordinator.confirmReplacement()
        #expect(control.events.filter { $0 == "decide" }.isEmpty)
        coordinator.selectReplacementTarget(cid: secondCID)
        await coordinator.confirmReplacement()

        #expect(control.decisionObservedAsDurable?.choice == .replaceDevice)
        #expect(control.decisionObservedAsDurable?.replacesCID == secondCID)
        #expect(control.events.filter { $0 == "decide" }.count == 1)
        #expect(try store.loadCarriedPairingRecord().decision == nil)
        #expect(try store.loadCarriedPairingRecord().replacementOfferID == nil)
        #expect(!coordinator.replacementPickerVisible)
    }

    @Test func freshReplacementConflictReplaysTheSameDurableDecisionAndExactTarget() async throws {
        let currentCID = "sha256:" + String(repeating: "b", count: 64)
        let targetCID = "sha256:" + String(repeating: "d", count: 64)
        let saved = pairingWithFingerprint(currentCID)
        let store = PairingStore(pairing: nil)
        let control = PairingControlScript(
            mode: .freshConflictAppliedReplay,
            store: store,
            clients: [CarriedPairingClientRow(cid: targetCID, displayLabel: "Laptop")]
        )
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(saved)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        await coordinator.refreshPendingActions(markConfirmed: true).value
        coordinator.markReplacementOfferShown()
        let persistedOfferID = try #require(try store.loadCarriedPairingRecord().replacementOfferID)
        await coordinator.openReplacementPicker()
        coordinator.selectReplacementTarget(cid: targetCID)
        await coordinator.confirmReplacement()

        #expect(control.decisionSnapshots.count == 2)
        #expect(control.decisionSnapshots[0] == control.decisionSnapshots[1])
        #expect(control.decisionSnapshots[0]?.decisionID == persistedOfferID)
        #expect(control.decisionSnapshots[0]?.choice == .replaceDevice)
        #expect(control.decisionSnapshots[0]?.replacesCID == targetCID)
        #expect(coordinator.pendingMigrationDecision == nil)
        #expect(try store.loadCarriedPairingRecord().decision == nil)
    }

    @Test func unresolvedFreshReplacementConflictKeepsTheExactDecisionPending() async throws {
        let currentCID = "sha256:" + String(repeating: "b", count: 64)
        let targetCID = "sha256:" + String(repeating: "d", count: 64)
        let saved = pairingWithFingerprint(currentCID)
        let store = PairingStore(pairing: nil)
        let control = PairingControlScript(
            mode: .freshConflictUnresolved,
            store: store,
            clients: [CarriedPairingClientRow(cid: targetCID, displayLabel: "Laptop")]
        )
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(saved)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        await coordinator.refreshPendingActions(markConfirmed: true).value
        coordinator.markReplacementOfferShown()
        await coordinator.openReplacementPicker()
        coordinator.selectReplacementTarget(cid: targetCID)
        await coordinator.confirmReplacement()
        let submitted = try #require(try store.loadCarriedPairingRecord().decision)
        await coordinator.keepBothDevices()

        #expect(control.decisionSnapshots == [submitted, submitted])
        #expect(coordinator.pendingMigrationDecision == submitted)
        #expect(coordinator.migrationDecisionState == "decision_unknown")
        #expect(try store.loadCarriedPairingRecord().decision == submitted)
        #expect(try store.loadCarriedPairingRecord().replacementOfferID == submitted.decisionID)
    }

    @Test func emptyAndSelfOnlyListRetiresFreshObligationAndDoesNotShowOffer() async throws {
        // Case 1: Empty list
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let saved = pairingWithFingerprint(selfCID)
        let store = PairingStore(pairing: nil)
        let control = PairingControlScript(
            mode: .accepted,
            store: store,
            clients: []
        )
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(saved)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        await coordinator.refreshPendingActions(markConfirmed: true).value

        var record = try store.loadCarriedPairingRecord()
        #expect(record.replacementOfferID == nil)
        #expect(!record.replacementOfferShown)
        #expect(record.decision == nil)
        #expect(record.freshPairObligation == nil)
        #expect(!coordinator.replacementOfferVisible)
        #expect(!coordinator.replacementPickerVisible)
        #expect(coordinator.replacementTargets.isEmpty)
        #expect(coordinator.selectedReplacementCID == nil)
        #expect(coordinator.migrationDecisionState == nil)
        #expect(!coordinator.replacementListUnavailable)
        #expect(control.events.filter { $0 == "decide" }.isEmpty)
        #expect(control.events.filter { $0 == "clients" }.count == 1)

        let coordinator2 = makeCoordinator(
            store: store,
            outcomes: [],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )
        await coordinator2.refreshPendingActions(markConfirmed: true).value
        #expect(!coordinator2.replacementOfferVisible)
        #expect(control.events.filter { $0 == "clients" }.count == 1)

        // Case 2: Self-only list
        let storeSelf = PairingStore(pairing: nil)
        let controlSelf = PairingControlScript(
            mode: .accepted,
            store: storeSelf,
            clients: [CarriedPairingClientRow(cid: selfCID, displayLabel: "My Mac")]
        )
        let coordinatorSelf = makeCoordinator(
            store: storeSelf,
            outcomes: [.success(saved)],
            carriedPairingControl: controlSelf.client,
            localPort: { 7070 }
        )

        await coordinatorSelf.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        await coordinatorSelf.refreshPendingActions(markConfirmed: true).value

        record = try storeSelf.loadCarriedPairingRecord()
        #expect(record.replacementOfferID == nil)
        #expect(!record.replacementOfferShown)
        #expect(record.decision == nil)
        #expect(record.freshPairObligation == nil)
        #expect(!coordinatorSelf.replacementOfferVisible)
        #expect(controlSelf.events.filter { $0 == "clients" }.count == 1)
    }

    @Test func nonEmptyClientsKeepsOfferAndPickerReloadsWithoutRetiring() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let otherCID = "sha256:" + String(repeating: "c", count: 64)
        let otherCID2 = "sha256:" + String(repeating: "d", count: 64)
        let saved = pairingWithFingerprint(selfCID)

        // (a) List not containing self
        let storeA = PairingStore(pairing: nil)
        let controlA = PairingControlScript(
            mode: .accepted,
            store: storeA,
            clients: [CarriedPairingClientRow(cid: otherCID, displayLabel: "Other")]
        )
        let coordA = makeCoordinator(store: storeA, outcomes: [.success(saved)], carriedPairingControl: controlA.client, localPort: { 7070 })
        await coordA.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        await coordA.refreshPendingActions(markConfirmed: true).value
        #expect(coordA.replacementOfferVisible)
        #expect(try storeA.loadCarriedPairingRecord().replacementOfferID != nil)
        #expect(!(try storeA.loadCarriedPairingRecord().replacementOfferShown))
        #expect(controlA.events.filter { $0 == "decide" }.isEmpty)

        // (b) Self plus other with picker reload
        let store = PairingStore(pairing: nil)
        let control = PairingControlScript(
            mode: .accepted,
            store: store,
            clients: [
                CarriedPairingClientRow(cid: selfCID, displayLabel: "Self"),
                CarriedPairingClientRow(cid: otherCID, displayLabel: "Laptop 1"),
                CarriedPairingClientRow(cid: otherCID2, displayLabel: "Laptop 2")
            ]
        )
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(saved)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        await coordinator.refreshPendingActions(markConfirmed: true).value
        #expect(coordinator.replacementOfferVisible)
        let initialOfferID = try #require(try store.loadCarriedPairingRecord().replacementOfferID)
        #expect(control.events.filter { $0 == "decide" }.isEmpty)

        coordinator.markReplacementOfferShown()
        await coordinator.openReplacementPicker()
        #expect(coordinator.replacementPickerVisible)
        #expect(coordinator.replacementTargets.count == 2)

        // Later picker reload returns only self (no other CID)
        control.enqueueClientsOutcome(.success([CarriedPairingClientRow(cid: selfCID, displayLabel: "Self")]))
        await coordinator.chooseAnotherReplacementDevice()
        #expect(coordinator.replacementPickerVisible)
        #expect(coordinator.replacementTargets.isEmpty)
        let recordAfterReload = try store.loadCarriedPairingRecord()
        #expect(recordAfterReload.replacementOfferID == initialOfferID)
        #expect(recordAfterReload.replacementOfferShown)
        #expect(recordAfterReload.decision == nil)
        #expect(control.events.filter { $0 == "decide" }.isEmpty)
    }

    @Test func clientsFailureKeepsOfferDurableAndRecoverable() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let saved = pairingWithFingerprint(selfCID)

        // Unavailable failure
        let store1 = PairingStore(pairing: nil)
        let control1 = PairingControlScript(mode: .accepted, store: store1)
        control1.enqueueClientsOutcome(.failure(.unavailable))
        let coordinator1 = makeCoordinator(
            store: store1,
            outcomes: [.success(saved)],
            carriedPairingControl: control1.client,
            localPort: { 7070 }
        )

        await coordinator1.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        await coordinator1.refreshPendingActions(markConfirmed: true).value

        let record1 = try store1.loadCarriedPairingRecord()
        #expect(record1.replacementOfferID != nil)
        #expect(!record1.replacementOfferShown)
        #expect(record1.decision == nil)
        #expect(record1.freshPairObligation == nil)
        #expect(coordinator1.replacementOfferVisible)

        let newCoordinator1 = makeCoordinator(
            store: store1,
            outcomes: [],
            carriedPairingControl: control1.client,
            localPort: { 7070 }
        )
        await newCoordinator1.refreshPendingActions(markConfirmed: true).value
        #expect(newCoordinator1.replacementOfferVisible)
        #expect(control1.events.filter { $0 == "clients" }.count == 1)

        // InvalidResponse failure
        let store2 = PairingStore(pairing: nil)
        let control2 = PairingControlScript(mode: .accepted, store: store2)
        control2.enqueueClientsOutcome(.failure(.invalidResponse))
        let coordinator2 = makeCoordinator(
            store: store2,
            outcomes: [.success(saved)],
            carriedPairingControl: control2.client,
            localPort: { 7070 }
        )

        await coordinator2.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        await coordinator2.refreshPendingActions(markConfirmed: true).value

        let record2 = try store2.loadCarriedPairingRecord()
        #expect(record2.replacementOfferID != nil)
        #expect(!record2.replacementOfferShown)
        #expect(record2.decision == nil)
        #expect(record2.freshPairObligation == nil)
        #expect(coordinator2.replacementOfferVisible)
    }

    @Test func crashWindowLeavesObligationDurableAndResolvableByNewCoordinator() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let otherCID = "sha256:" + String(repeating: "c", count: 64)
        let saved = pairingWithFingerprint(selfCID)
        let store = PairingStore(pairing: nil)
        let reactivateGate = OneShotContinuationGate()
        let reactivateStarted = LockedCounter()
        let control = PairingControlScript(
            mode: .accepted,
            store: store,
            clients: [
                CarriedPairingClientRow(cid: selfCID, displayLabel: "Laptop"),
                CarriedPairingClientRow(cid: otherCID, displayLabel: "Other")
            ]
        )
        let coordinator1 = makeCoordinator(
            store: store,
            outcomes: [.success(saved)],
            reactivateGate: reactivateGate,
            reactivateStarted: reactivateStarted,
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        let pairTask = Task { await coordinator1.submitPairingLink(relayPairLink(instanceID: saved.instanceID)) }
        await reactivateStarted.waitUntilCount(1)

        // While blocked in the crash interval before reactivate:
        #expect(store.currentPairing == saved)
        let pendingRecord = try store.loadCarriedPairingRecord()
        #expect(pendingRecord.freshPairObligation == PairingCredentialRevision(from: saved))
        #expect(pendingRecord.replacementOfferID == nil)
        #expect(!pendingRecord.replacementOfferShown)
        #expect(control.events.filter { $0 == "clients" }.isEmpty)

        // A second coordinator resolves the obligation
        let coordinator2 = makeCoordinator(
            store: store,
            outcomes: [],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )
        await coordinator2.refreshPendingActions(markConfirmed: true).value
        #expect(coordinator2.replacementOfferVisible)
        #expect(try store.loadCarriedPairingRecord().replacementOfferID != nil)
        #expect(try store.loadCarriedPairingRecord().freshPairObligation == nil)

        reactivateGate.release()
        await pairTask.value
        #expect(control.events.filter { $0 == "clients" }.count == 1)

        // .alreadyConnected writes no obligation and no offer
        let rePairRefreshed = pairingWithFingerprint(selfCID)
        let rePairStore = PairingStore(pairing: saved)
        let rePairCoordinator = makeCoordinator(
            store: rePairStore,
            outcomes: [.success(rePairRefreshed)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )
        await rePairCoordinator.submitPairingLink(try directPairLink(caPEM: testCACertPEM))
        #expect(rePairCoordinator.state == .alreadyConnected)
        let rePairRecord = try rePairStore.loadCarriedPairingRecord()
        #expect(rePairRecord.freshPairObligation == nil)
        #expect(rePairRecord.replacementOfferID == nil)

        // Thrown credential save leaves prior pairing, prior record with seeded offer, and 0 clients calls
        let priorPairing = pairingWithFingerprint("sha256:" + String(repeating: "a", count: 64))
        let failStore = PairingStore(pairing: priorPairing, saveError: PairScriptError.saveFailed)
        var priorRecord = CarriedPairingRecord.empty
        priorRecord.replacementOfferID = "prior-offer-id"
        try failStore.saveCarriedPairingRecord(priorRecord)
        let failControl = PairingControlScript(mode: .accepted, store: failStore)
        let failCoordinator = makeCoordinator(
            store: failStore,
            outcomes: [.success(saved)],
            retireOwnCredential: { _, _ in true },
            carriedPairingControl: failControl.client,
            localPort: { 7070 }
        )
        let failLink = try relayPairLink(caPEM: otherCACertPEM)
        await failCoordinator.submitPairingLink(failLink)
        await failCoordinator.confirmSwitch()
        #expect(failCoordinator.state == PairingFlowState.saveFailed)
        #expect(failStore.currentPairing == priorPairing)
        #expect(try failStore.loadCarriedPairingRecord().replacementOfferID == "prior-offer-id")
        #expect(failControl.events.filter { $0 == "clients" }.isEmpty)
    }

    @Test func crashWindowResolvesEmptyAndUnavailable() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let saved = pairingWithFingerprint(selfCID)

        // Case 1: Second coordinator's clients() returns [] -> retires
        let storeEmpty = PairingStore(pairing: nil)
        let reactivateGate1 = OneShotContinuationGate()
        let reactivateStarted1 = LockedCounter()
        let control1 = PairingControlScript(mode: .accepted, store: storeEmpty)
        let coordinator1 = makeCoordinator(
            store: storeEmpty,
            outcomes: [.success(saved)],
            reactivateGate: reactivateGate1,
            reactivateStarted: reactivateStarted1,
            carriedPairingControl: control1.client,
            localPort: { 7070 }
        )
        let pairTask1 = Task { await coordinator1.submitPairingLink(relayPairLink(instanceID: saved.instanceID)) }
        await reactivateStarted1.waitUntilCount(1)

        let control2 = PairingControlScript(mode: .accepted, store: storeEmpty, clients: [])
        let coordinator2 = makeCoordinator(
            store: storeEmpty,
            outcomes: [],
            carriedPairingControl: control2.client,
            localPort: { 7070 }
        )
        await coordinator2.refreshPendingActions(markConfirmed: true).value
        var recordEmpty = try storeEmpty.loadCarriedPairingRecord()
        #expect(recordEmpty.freshPairObligation == nil)
        #expect(recordEmpty.replacementOfferID == nil)
        #expect(!recordEmpty.replacementOfferShown)
        #expect(recordEmpty.decision == nil)
        #expect(!coordinator2.replacementOfferVisible)
        #expect(control2.events.filter { $0 == "decide" }.isEmpty)

        reactivateGate1.release()
        await pairTask1.value
        #expect(control1.events.filter { $0 == "clients" }.isEmpty)
        recordEmpty = try storeEmpty.loadCarriedPairingRecord()
        #expect(recordEmpty.replacementOfferID == nil)

        // Case 2: Second coordinator's clients() throws .unavailable -> offer kept
        let storeUnavail = PairingStore(pairing: nil)
        let reactivateGate2 = OneShotContinuationGate()
        let reactivateStarted2 = LockedCounter()
        let control3 = PairingControlScript(mode: .accepted, store: storeUnavail, clients: [])
        control3.enqueueClientsOutcome(.failure(.invalidResponse))
        let coordinator3 = makeCoordinator(
            store: storeUnavail,
            outcomes: [.success(saved)],
            reactivateGate: reactivateGate2,
            reactivateStarted: reactivateStarted2,
            carriedPairingControl: control3.client,
            localPort: { 7070 }
        )
        let pairTask2 = Task { await coordinator3.submitPairingLink(relayPairLink(instanceID: saved.instanceID)) }
        await reactivateStarted2.waitUntilCount(1)

        let control4 = PairingControlScript(mode: .accepted, store: storeUnavail)
        control4.enqueueClientsOutcome(.failure(.unavailable))
        let coordinator4 = makeCoordinator(
            store: storeUnavail,
            outcomes: [],
            carriedPairingControl: control4.client,
            localPort: { 7070 }
        )
        await coordinator4.refreshPendingActions(markConfirmed: true).value
        var recordUnavail = try storeUnavail.loadCarriedPairingRecord()
        let persistedOfferID = try #require(recordUnavail.replacementOfferID)
        #expect(recordUnavail.freshPairObligation == nil)
        #expect(!recordUnavail.replacementOfferShown)
        #expect(recordUnavail.decision == nil)
        #expect(coordinator4.replacementOfferVisible)
        #expect(control4.events.filter { $0 == "decide" }.isEmpty)

        reactivateGate2.release()
        await pairTask2.value
        recordUnavail = try storeUnavail.loadCarriedPairingRecord()
        #expect(recordUnavail.replacementOfferID == persistedOfferID)
        #expect(recordUnavail.freshPairObligation == nil)
        #expect(control3.events.filter { $0 == "clients" }.isEmpty)
    }

    @Test func stopInsideClientsOldTaskLosesToSecondCoordinator() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let otherCID = "sha256:" + String(repeating: "c", count: 64)
        let saved = pairingWithFingerprint(selfCID)

        // Observation 1: First script returns [] (would retire). Second script returns other CID (keeps offer).
        let store1 = PairingStore(pairing: nil)
        let gate1 = OneShotContinuationGate()
        let control1 = PairingControlScript(mode: .accepted, store: store1, clients: [], clientsGate: gate1)
        let coord1 = makeCoordinator(store: store1, outcomes: [.success(saved)], carriedPairingControl: control1.client, localPort: { 7070 })
        await coord1.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        let task1 = Task { await coord1.refreshPendingActions(markConfirmed: true).value }
        await control1.waitUntilClientsStart()

        let control2 = PairingControlScript(mode: .accepted, store: store1, clients: [CarriedPairingClientRow(cid: otherCID, displayLabel: "Other")])
        let coord2 = makeCoordinator(store: store1, outcomes: [], carriedPairingControl: control2.client, localPort: { 7070 })
        await coord2.refreshPendingActions(markConfirmed: true).value
        let offerID2 = try #require(try store1.loadCarriedPairingRecord().replacementOfferID)
        #expect(coord2.replacementOfferVisible)

        gate1.release()
        await task1.value

        let finalRecord1 = try store1.loadCarriedPairingRecord()
        #expect(finalRecord1.replacementOfferID == offerID2)
        #expect(finalRecord1.freshPairObligation == nil)
        #expect(coord2.replacementOfferVisible)
        #expect(!coord1.replacementOfferVisible)
        #expect(control1.events.filter { $0 == "decide" }.isEmpty)
        #expect(control2.events.filter { $0 == "decide" }.isEmpty)

        // Observation 2: First script returns other CID. Second script returns [] and retires.
        let store2 = PairingStore(pairing: nil)
        let gate2 = OneShotContinuationGate()
        let control3 = PairingControlScript(mode: .accepted, store: store2, clients: [CarriedPairingClientRow(cid: otherCID, displayLabel: "Other")], clientsGate: gate2)
        let coord3 = makeCoordinator(store: store2, outcomes: [.success(saved)], carriedPairingControl: control3.client, localPort: { 7070 })
        await coord3.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        let task2 = Task { await coord3.refreshPendingActions(markConfirmed: true).value }
        await control3.waitUntilClientsStart()

        let control4 = PairingControlScript(mode: .accepted, store: store2, clients: [])
        let coord4 = makeCoordinator(store: store2, outcomes: [], carriedPairingControl: control4.client, localPort: { 7070 })
        await coord4.refreshPendingActions(markConfirmed: true).value
        #expect(try store2.loadCarriedPairingRecord().replacementOfferID == nil)
        #expect(!coord4.replacementOfferVisible)

        gate2.release()
        await task2.value

        let finalRecord2 = try store2.loadCarriedPairingRecord()
        #expect(finalRecord2.replacementOfferID == nil)
        #expect(finalRecord2.freshPairObligation == nil)
        #expect(!coord3.replacementOfferVisible)
        #expect(!coord4.replacementOfferVisible)

        // Observation 3: First script throws .invalidResponse. Second script throws .unavailable and keeps offer.
        let store3 = PairingStore(pairing: nil)
        let gate3 = OneShotContinuationGate()
        let control5 = PairingControlScript(mode: .accepted, store: store3, clientsGate: gate3)
        control5.enqueueClientsOutcome(.failure(.invalidResponse), gate: gate3)
        let coord5 = makeCoordinator(store: store3, outcomes: [.success(saved)], carriedPairingControl: control5.client, localPort: { 7070 })
        await coord5.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        let task3 = Task { await coord5.refreshPendingActions(markConfirmed: true).value }
        await control5.waitUntilClientsStart()

        let control6 = PairingControlScript(mode: .accepted, store: store3)
        control6.enqueueClientsOutcome(.failure(.unavailable))
        let coord6 = makeCoordinator(store: store3, outcomes: [], carriedPairingControl: control6.client, localPort: { 7070 })
        await coord6.refreshPendingActions(markConfirmed: true).value
        let writtenOfferID = try #require(try store3.loadCarriedPairingRecord().replacementOfferID)

        gate3.release()
        await task3.value

        let finalRecord3 = try store3.loadCarriedPairingRecord()
        #expect(finalRecord3.replacementOfferID == writtenOfferID)
        #expect(finalRecord3.freshPairObligation == nil)
        #expect(!finalRecord3.replacementOfferShown)
    }

    @Test func unpairThenPairAgainWhileClientsIsParked() async throws {
        let firstPairing = pairingWithFingerprint("sha256:" + String(repeating: "b", count: 64))
        let repairedPairing = pairingWithFingerprint("sha256:" + String(repeating: "c", count: 64))
        let store = PairingStore(pairing: nil)
        let gate = OneShotContinuationGate()
        let control = PairingControlScript(mode: .accepted, store: store, clients: [], clientsGate: gate)
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(firstPairing), .success(repairedPairing)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: firstPairing.instanceID))
        let firstRefresh = Task { await coordinator.refreshPendingActions(markConfirmed: true).value }
        await control.waitUntilClientsStart()

        #expect(await coordinator.unpair())
        await coordinator.submitPairingLink(relayPairLink(instanceID: repairedPairing.instanceID))

        let snapshotRecord = try store.loadCarriedPairingRecord()
        #expect(snapshotRecord.freshPairObligation == PairingCredentialRevision(from: repairedPairing))
        #expect(snapshotRecord.replacementOfferID == nil)

        gate.release()
        await firstRefresh.value

        let finalRecord = try store.loadCarriedPairingRecord()
        #expect(finalRecord == snapshotRecord)
        #expect(finalRecord.freshPairObligation == PairingCredentialRevision(from: repairedPairing))
        #expect(finalRecord.replacementOfferID == nil)
        #expect(finalRecord.decision == nil)
        #expect(control.events.filter { $0 == "decide" }.isEmpty)
        #expect(!coordinator.replacementOfferVisible)
    }

    @Test func credentialChangeWhileClientsIsParkedDiscardsLateResult() async throws {
        let firstPairing = pairingWithFingerprint("sha256:" + String(repeating: "b", count: 64))
        let changedPairing = pairingWithFingerprint("sha256:" + String(repeating: "d", count: 64))
        let otherCID = "sha256:" + String(repeating: "e", count: 64)
        let store = PairingStore(pairing: nil)
        let gate = OneShotContinuationGate()
        let control = PairingControlScript(
            mode: .accepted,
            store: store,
            clients: [CarriedPairingClientRow(cid: otherCID, displayLabel: "Other")],
            clientsGate: gate
        )
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(firstPairing)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: firstPairing.instanceID))
        let refreshTask = Task { await coordinator.refreshPendingActions(markConfirmed: true).value }
        await control.waitUntilClientsStart()

        // Bypass activate and save a different credential directly
        try store.save(changedPairing)
        let snapshotRecord = try store.loadCarriedPairingRecord()

        gate.release()
        await refreshTask.value

        let finalRecord = try store.loadCarriedPairingRecord()
        #expect(finalRecord == snapshotRecord)
        #expect(finalRecord.freshPairObligation == PairingCredentialRevision(from: firstPairing))
        #expect(finalRecord.replacementOfferID == nil)
        #expect(!coordinator.replacementOfferVisible)
        #expect(control.events.filter { $0 == "decide" }.isEmpty)
    }

    @Test func parkInsideClientsAllowsAdmissionAndVerifiesPreRequisites() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let otherCID = "sha256:" + String(repeating: "c", count: 64)
        let saved = pairingWithFingerprint(selfCID)
        let store = PairingStore(pairing: nil)
        let credentials = PairingCredentialStore(store: store)
        let clientsGate = OneShotContinuationGate()
        let control = PairingControlScript(
            mode: .accepted,
            store: store,
            clients: [
                CarriedPairingClientRow(cid: selfCID, displayLabel: "Laptop"),
                CarriedPairingClientRow(cid: otherCID, displayLabel: "Other")
            ],
            clientsGate: clientsGate
        )
        let portHolder = LockedValue<Int>()
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(saved)],
            reactivate: reactivate,
            carriedPairingControl: control.client,
            localPort: { portHolder.current }
        )

        // Refresh before obligation exists: no clients
        _ = coordinator.refreshPendingActions(markConfirmed: true)
        #expect(control.events.filter { $0 == "clients" }.isEmpty)

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        #expect(await reactivate.count == 1)

        // Admission is ready while obligation is pending
        #expect(credentials.admission(for: saved) == .ready)

        // Refresh with markConfirmed == false: no clients
        _ = coordinator.refreshPendingActions(markConfirmed: false)
        #expect(!coordinator.replacementOfferVisible)
        #expect(control.events.filter { $0 == "clients" }.isEmpty)

        // Refresh with portHolder nil: no clients
        _ = coordinator.refreshPendingActions(markConfirmed: true)
        #expect(!coordinator.replacementOfferVisible)
        #expect(control.events.filter { $0 == "clients" }.isEmpty)

        // Mark confirmed and port set -> reaches clients()
        portHolder.set(7070)
        let refreshTask = Task { await coordinator.refreshPendingActions(markConfirmed: true).value }
        await control.waitUntilClientsStart()

        // Admission is still ready while parked in clients()
        #expect(credentials.admission(for: saved) == .ready)

        clientsGate.release()
        await refreshTask.value

        #expect(coordinator.replacementOfferVisible)
        #expect(try store.loadCarriedPairingRecord().freshPairObligation == nil)
    }

    @Test func parkedClientsIgnoresDuplicateRefreshAndHandlesConcurrentMutationsAndRetries() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let otherCID = "sha256:" + String(repeating: "c", count: 64)
        let saved = pairingWithFingerprint(selfCID)
        let store = PairingStore(pairing: nil)
        let clientsGate = OneShotContinuationGate()
        let control = PairingControlScript(
            mode: .accepted,
            store: store,
            clients: [CarriedPairingClientRow(cid: otherCID, displayLabel: "Other")],
            clientsGate: clientsGate
        )
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [.success(saved)],
            carriedPairingControl: control.client,
            localPort: { 7070 }
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: saved.instanceID))
        let firstRefresh = Task { await coordinator.refreshPendingActions(markConfirmed: true).value }
        await control.waitUntilClientsStart()

        // Duplicate refresh while in flight: does not start second clients read and does not set shown
        _ = coordinator.refreshPendingActions(markConfirmed: true)
        #expect(control.events.filter { $0 == "clients" }.count == 1)
        #expect(!(try store.loadCarriedPairingRecord().replacementOfferShown))

        // Save error armed after attempt save and before gate release
        store.setCarriedRecordSaveError(PairScriptError.saveFailed)
        clientsGate.release()
        await firstRefresh.value

        // Obligation remains due to save failure
        var record = try store.loadCarriedPairingRecord()
        #expect(record.freshPairObligation == PairingCredentialRevision(from: saved))

        // Clearing error allows subsequent refresh to resolve
        store.setCarriedRecordSaveError(nil)
        await coordinator.refreshPendingActions(markConfirmed: true).value
        record = try store.loadCarriedPairingRecord()
        #expect(record.freshPairObligation == nil)
        #expect(record.replacementOfferID != nil)
        #expect(coordinator.replacementOfferVisible)

        // Stale winner test: coordinator 1 parked, coordinator 2 modifies decision
        let gate2 = OneShotContinuationGate()
        let storeRace = PairingStore(pairing: saved)
        let revision = PairingCredentialRevision(from: saved)
        var oblRecord = CarriedPairingRecord.empty
        oblRecord.freshPairObligation = revision
        try storeRace.saveCarriedPairingRecord(oblRecord)

        let controlRace = PairingControlScript(
            mode: .accepted,
            store: storeRace,
            clients: [CarriedPairingClientRow(cid: otherCID, displayLabel: "Other")],
            clientsGate: gate2
        )
        let raceCoord1 = makeCoordinator(store: storeRace, outcomes: [], carriedPairingControl: controlRace.client, localPort: { 7070 })
        let raceTask = Task { await raceCoord1.refreshPendingActions(markConfirmed: true).value }
        await controlRace.waitUntilClientsStart()

        // Concurrent winner writes a decision
        var winnerRecord = try storeRace.loadCarriedPairingRecord()
        winnerRecord.decision = CarriedPairingDecision(
            decisionID: "winner-decision",
            choice: .newDevice,
            replacesCID: nil,
            credentialFingerprint: saved.fingerprint,
            credentialRevision: revision.revision
        )
        try storeRace.saveCarriedPairingRecord(winnerRecord)

        gate2.release()
        await raceTask.value

        // Winner's record was not overwritten
        let finalRaceRecord = try storeRace.loadCarriedPairingRecord()
        #expect(finalRaceRecord.decision?.decisionID == "winner-decision")
        #expect(!raceCoord1.replacementOfferVisible)
    }

    @Test func legacyAndCompletedRecordsDoNotTriggerFreshEligibility() async throws {
        let selfCID = "sha256:" + String(repeating: "b", count: 64)
        let saved = pairingWithFingerprint(selfCID)

        // Legacy empty record
        let legacyStore = PairingStore(pairing: saved)
        try legacyStore.saveCarriedPairingRecord(.empty)
        let legacyControl = PairingControlScript(mode: .accepted, store: legacyStore, clients: [CarriedPairingClientRow(cid: "other", displayLabel: "Other")])
        let legacyCoord = makeCoordinator(store: legacyStore, outcomes: [], carriedPairingControl: legacyControl.client, localPort: { 7070 })

        await legacyCoord.refreshPendingActions(markConfirmed: true).value
        #expect(legacyControl.events.filter { $0 == "clients" }.isEmpty)
        #expect(!legacyCoord.replacementOfferVisible)

        // Completed record
        let completedStore = PairingStore(pairing: saved)
        var completedRecord = CarriedPairingRecord.empty
        completedRecord.replacementOfferShown = true
        try completedStore.saveCarriedPairingRecord(completedRecord)
        let completedControl = PairingControlScript(mode: .accepted, store: completedStore, clients: [CarriedPairingClientRow(cid: "other", displayLabel: "Other")])
        let completedCoord = makeCoordinator(store: completedStore, outcomes: [], carriedPairingControl: completedControl.client, localPort: { 7070 })

        await completedCoord.refreshPendingActions(markConfirmed: true).value
        #expect(completedControl.events.filter { $0 == "clients" }.isEmpty)
        #expect(!completedCoord.replacementOfferVisible)

        // JSON omitting new keys decodes with nil obligation & admission is ready
        let legacyJSON = """
        {"replacementOfferShown":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CarriedPairingRecord.self, from: legacyJSON)
        #expect(decoded.freshPairObligation == nil)
        #expect(decoded.freshPairEligibilityAttempt == nil)
        #expect(decoded.replacementOfferID == nil)
        #expect(!decoded.replacementOfferShown)
        #expect(decoded.decision == nil)
        #expect(decoded.invalidation == nil)

        let credStore = PairingCredentialStore(store: legacyStore)
        #expect(credStore.admission(for: saved) == .ready)
    }

    @Test func confirmedSwitchReplacesPriorOfferWithFreshObligation() async throws {
        let old = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: testCACertPEM)
        let replacement = pairing(instanceID: "22222222-2222-2222-2222-222222222222", caChainPEM: otherCACertPEM)
        let store = PairingStore(pairing: old)
        var priorRecord = CarriedPairingRecord.empty
        priorRecord.replacementOfferID = "prior-offer-id"
        priorRecord.replacementOfferShown = false
        try store.saveCarriedPairingRecord(priorRecord)

        let script = PairScript([.success(replacement)])
        let coordinator = makeCoordinator(store: store, script: script, retireOwnCredential: { _, _ in true })

        let link = try relayPairLink(caPEM: otherCACertPEM)
        await coordinator.submitPairingLink(link)
        #expect(coordinator.state == .switchConfirmPending)

        await coordinator.confirmSwitch()
        #expect(coordinator.state == .switched)

        let record = try store.loadCarriedPairingRecord()
        #expect(record.replacementOfferID == nil)
        #expect(record.freshPairObligation == PairingCredentialRevision(from: replacement))
        #expect(!record.replacementOfferShown)

        _ = coordinator.refreshPendingActions(markConfirmed: false)
        #expect(!coordinator.replacementOfferVisible)
    }

    // Acceptance 9: linkNamesJournal checks.
    @Test func linkNamesJournalEvaluations() async throws {
        let multiCertCA = otherCACertPEM + "\n" + testCACertPEM
        let stored = pairing(caChainPEM: multiCertCA)

        let matchingDirect = try PairURL(string: directPairLink(caPEM: testCACertPEM))
        #expect(PairingCoordinator.linkNamesJournal(matchingDirect, of: stored))

        let matchingRelay = try PairURL(string: relayPairLink(caPEM: testCACertPEM))
        #expect(PairingCoordinator.linkNamesJournal(matchingRelay, of: stored))

        let unrelatedStored = pairing(caChainPEM: otherCACertPEM)
        #expect(!PairingCoordinator.linkNamesJournal(matchingDirect, of: unrelatedStored))
        #expect(!PairingCoordinator.linkNamesJournal(matchingRelay, of: unrelatedStored))

        let unparseableStored = pairing(caChainPEM: "fixture-ca")
        #expect(!PairingCoordinator.linkNamesJournal(matchingDirect, of: unparseableStored))
        #expect(!PairingCoordinator.linkNamesJournal(matchingRelay, of: unparseableStored))
    }

    // Acceptance 11: Save throws after retire in same-journal re-pair.
    @Test func sameJournalSaveThrowsAfterRetireCallsEndSelfRetirementSetsSaveFailed() async throws {
        let multiCertCA = otherCACertPEM + "\n" + testCACertPEM
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: multiCertCA)
        let refreshed = pairing(instanceID: "11111111-1111-1111-1111-111111111111", caChainPEM: multiCertCA)
        let order = OrderRecorder()
        let store = PairingStore(pairing: prior, saveError: PairScriptError.saveFailed)
        let script = PairScript([.success(refreshed)])
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(
            store: store,
            script: script,
            reactivate: reactivate,
            onSave: {
                order.record("save")
            },
            retireOwnCredential: { _, _ in
                order.record("retire")
                return true
            },
            endSelfRetirement: {
                order.record("endSelfRetirement")
            }
        )

        let link = try directPairLink(caPEM: testCACertPEM)
        await coordinator.submitPairingLink(link)

        #expect(coordinator.state == .saveFailed)
        #expect(store.currentPairing == prior)
        #expect(await reactivate.count == 0)
        #expect(order.events == ["retire", "endSelfRetirement"])
    }

    @Test func invalidPairURLCasesMapToInvalidLink() async throws {
        let coordinator = makeCoordinator(store: PairingStore(pairing: nil), outcomes: [])

        await coordinator.submitPairingLink("not a url")
        #expect(coordinator.state == .failed(.invalidLink("pairing link must use https")))

        let cases: [(PairURLError, String)] = [
            (.wrongScheme(nil), "pairing link must use https"),
            (.wrongScheme("http"), "pairing link must use https, got http"),
            (.wrongHost(nil), "pairing link must use go.solstone.app"),
            (.wrongHost("example.com"), "pairing link must use go.solstone.app, got example.com"),
            (.wrongPath("/x"), "pairing link path must be /p, got /x"),
            (.missingFragment, "pairing link is missing its code"),
            (.invalidBase32(.outOfAlphabet("?")), "pairing link contains an invalid character: ?"),
            (.invalidBase32(.nonCanonicalPadBits), "pairing link contains invalid encoded data"),
            (.invalidVersion(0x02), "pairing link version is unsupported: 0x02"),
            (.unsupportedAddrType(0xff), "pairing link address type is unsupported: 0xff"),
            (.unsupportedCAFingerprintTag(0x02), "pairing link fingerprint type is unsupported: 0x02"),
            (.invalidRelayOrigin, "pairing link relay origin is invalid"),
            (.invalidLength(12), "pairing link data length is invalid: 12 bytes"),
            (.malformedOuterURL, "pairing link is malformed"),
        ]

        for (error, expected) in cases {
            #expect(PairingCoordinator.invalidLinkReason(error) == expected)
        }
    }

    @Test func directSingleCandidatePairLinkRunsCeremonyAndSaves() async throws {
        let saved = pairing(instanceID: "11111111-1111-1111-1111-111111111111")
        let store = PairingStore(pairing: nil)
        let script = PairScript([.success(saved)])
        let reactivate = ReactivateRecorder()
        let clear = ClearRecorder()
        let coordinator = makeCoordinator(store: store, script: script, reactivate: reactivate, clear: clear)

        await coordinator.submitPairingLink(directPairLink)

        #expect(coordinator.state == .paired)
        #expect(store.currentPairing == saved)
        #expect(store.savedPairings == [saved])
        #expect(store.saveCount == 1)
        #expect(await script.callCount == 1)
        #expect(await reactivate.count == 1)
        #expect(clear.count == 1)

        let calls = await script.calls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.pairURL.kind == .direct)
        #expect(call.pairURL.candidates == [
            PairCandidate(address: "192.168.1.42", port: 7070),
        ])
    }

    @Test func directMultiCandidatePairLinkPreservesParsedCandidateOrder() async throws {
        let saved = pairing(instanceID: "11111111-1111-1111-1111-111111111111")
        let store = PairingStore(pairing: nil)
        let script = PairScript([.success(saved)])
        let coordinator = makeCoordinator(store: store, script: script)

        await coordinator.submitPairingLink(directMultiCandidatePairLink)

        #expect(coordinator.state == .paired)
        #expect(await script.callCount == 1)

        let calls = await script.calls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.pairURL.kind == .direct)
        #expect(call.pairURL.candidates == [
            PairCandidate(address: "10.0.0.7", port: 7070),
            PairCandidate(address: "100.64.3.9", port: 7070),
        ])
    }

    @Test func attestationRejected401MapsToStaleLink() async throws {
        await expectCeremonyFailure(PairError.attestationRejected(status: 401), mapsTo: .staleLink)
    }

    @Test func attestationRejected403MapsToStaleLink() async throws {
        await expectCeremonyFailure(PairError.attestationRejected(status: 403), mapsTo: .staleLink)
    }

    @Test func attestationRejected409MapsToStaleLink() async throws {
        await expectCeremonyFailure(PairError.attestationRejected(status: 409), mapsTo: .staleLink)
    }

    @Test func nonceExpiredMapsToStaleLink() async throws {
        await expectCeremonyFailure(PairError.nonceExpired, mapsTo: .staleLink)
    }

    @Test func pairingWindowClosedMapsToStaleLink() async throws {
        await expectCeremonyFailure(PairError.pairingWindowClosed, mapsTo: .staleLink)
        await expectCeremonyFailure(DialError.pairingWindowClosed, mapsTo: .staleLink)
        #expect(PairingFailure.staleLink.message == "this pairing window closed or expired. get a fresh link from your journal's network app and try again.")
    }

    @Test func lanClosedBeforeResponseMapsToConnectionDropped() async throws {
        #expect(PairingCoordinator.failure(for: PairError.lanClosedBeforeResponse) == .connectionDropped)
        #expect(PairingFailure.connectionDropped.message == "lost the connection to your journal before it answered. try again.")
        #expect(PairingFailure.connectionDropped.message != PairingFailure.staleLink.message)
        await expectCeremonyFailure(PairError.lanClosedBeforeResponse, mapsTo: .connectionDropped)
    }

    @Test func relayCloseUnauthorizedMapsToStaleLink() async throws {
        await expectCeremonyFailure(DialError.relayCloseUnauthorized, mapsTo: .staleLink)
    }

    @Test func directAddressNotLocalMapsToDirectInvalidLinkCopy() async throws {
        await expectCeremonyFailure(
            PairError.directAddressNotLocal,
            mapsTo: .invalidLink("this pairing link contains an address that can't be used for direct pairing. get a fresh link from your journal and try again.")
        )
    }

    @Test func relayUnauthorizedMapsToRelayUnauthorized() async throws {
        await expectCeremonyFailure(DialError.relayUnauthorized, mapsTo: .relayUnauthorized)
        #expect(PairingCoordinator.failure(for: PairError.relayResponseInvalid(status: 401)) == .relayUnauthorized)
        #expect(PairingCoordinator.failure(for: PairError.relayResponseInvalid(status: 403)) == .relayUnauthorized)
        #expect(PairingCoordinator.failure(for: DialError.wsHandshakeFailed(httpStatus: 401)) == .relayUnauthorized)
        #expect(PairingCoordinator.failure(for: DialError.wsHandshakeFailed(httpStatus: 403)) == .relayUnauthorized)
    }

    @Test func relayInstanceMismatchMapsToInstanceMismatch() async throws {
        await expectCeremonyFailure(PairError.relayInstanceMismatch, mapsTo: .instanceMismatch)
        #expect(PairingCoordinator.failure(for: DialError.relayInstanceUnknown) == .instanceMismatch)
        #expect(PairingCoordinator.failure(for: DialError.wsHandshakeFailed(httpStatus: 404)) == .instanceMismatch)
    }

    @Test func dialRelayFailureMapsToHomeUnreachable() async throws {
        await expectCeremonyFailure(DialError.connectTimeout, mapsTo: .homeUnreachable)
        #expect(PairingCoordinator.failure(for: DialError.connectionFailed("offline")) == .homeUnreachable)
        #expect(PairingCoordinator.failure(for: DialError.sendFailed("closed")) == .homeUnreachable)
        #expect(PairingCoordinator.failure(for: DialError.receiveFailed("closed")) == .homeUnreachable)
        #expect(PairingCoordinator.failure(for: DialError.unexpectedTextFrame) == .homeUnreachable)
        #expect(PairingCoordinator.failure(for: PairError.lanCandidatesExhausted(sawCAFingerprintMismatch: false)) == .homeUnreachable)
        #expect(PairingCoordinator.failure(for: PairError.lanCandidatesExhausted(sawCAFingerprintMismatch: true)) == .instanceMismatch)
    }

    @Test func underlyingRelayNetworkFailureMapsToNetwork() async throws {
        await expectCeremonyFailure(PairError.relayRequestFailed(underlying: URLError(.cannotConnectToHost)), mapsTo: .network)
        #expect(PairingCoordinator.failure(for: PairError.relayResponseInvalid(status: nil)) == .network)
        #expect(PairingCoordinator.failure(for: PairError.lanResponseInvalid(status: 400)) == .network)
        #expect(PairingCoordinator.failure(for: DialError.wsHandshakeFailed(httpStatus: nil)) == .network)
    }

    @Test func ceremonyFailureEmitsPairingRefusedClassification() async throws {
        let log = RecordingClassifiedLogSink()
        let coordinator = makeCoordinator(
            store: PairingStore(pairing: nil),
            outcomes: [.failure(PairError.nonceExpired)],
            classifiedLog: log
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: "11111111-1111-1111-1111-111111111111"))

        let emission = try #require(log.emissions.first)
        #expect(emission.level == .notice)
        #expect(emission.classification == "pairing-refused")
        #expect(emission.publicFields["errorType"] == "PairError")
    }

    private func expectCeremonyFailure(_ error: any Error & Sendable, mapsTo failure: PairingFailure) async {
        let instanceID = "11111111-1111-1111-1111-111111111111"
        let coordinator = makeCoordinator(
            store: PairingStore(pairing: nil),
            outcomes: [.failure(error)]
        )

        await coordinator.submitPairingLink(relayPairLink(instanceID: instanceID))

        #expect(coordinator.state == .failed(failure))
    }

    private func makeCoordinator(
        store: PairingStore,
        outcomes: [PairScriptOutcome],
        reactivate: ReactivateRecorder = ReactivateRecorder(),
        reactivateGate: OneShotContinuationGate? = nil,
        reactivateStarted: LockedCounter? = nil,
        clear: ClearRecorder = ClearRecorder(),
        onSave: @escaping @Sendable () -> Void = {},
        retireOwnCredential: @escaping @MainActor @Sendable (StoredPairing, String) async -> Bool = { _, _ in true },
        endSelfRetirement: @escaping @MainActor @Sendable () -> Void = {},
        carriedPairingControl: any CarriedPairingControlRequesting = URLSessionCarriedPairingControlClient(),
        localPort: @escaping @MainActor @Sendable () -> Int? = { nil },
        classifiedLog: any ClassifiedLogSinking = LoggerClassifiedLogSink.general
    ) -> PairingCoordinator {
        makeCoordinator(
            store: store,
            script: PairScript(outcomes),
            reactivate: reactivate,
            reactivateGate: reactivateGate,
            reactivateStarted: reactivateStarted,
            clear: clear,
            onSave: onSave,
            retireOwnCredential: retireOwnCredential,
            endSelfRetirement: endSelfRetirement,
            carriedPairingControl: carriedPairingControl,
            localPort: localPort,
            classifiedLog: classifiedLog
        )
    }

    private func makeCoordinator(
        store: PairingStore,
        script: PairScript,
        reactivate: ReactivateRecorder = ReactivateRecorder(),
        reactivateGate: OneShotContinuationGate? = nil,
        reactivateStarted: LockedCounter? = nil,
        ownerState: TunnelLifecycleState = .disconnected,
        clear: ClearRecorder = ClearRecorder(),
        onSave: @escaping @Sendable () -> Void = {},
        retireOwnCredential: @escaping @MainActor @Sendable (StoredPairing, String) async -> Bool = { _, _ in true },
        endSelfRetirement: @escaping @MainActor @Sendable () -> Void = {},
        carriedPairingControl: any CarriedPairingControlRequesting = URLSessionCarriedPairingControlClient(),
        localPort: @escaping @MainActor @Sendable () -> Int? = { nil },
        classifiedLog: any ClassifiedLogSinking = LoggerClassifiedLogSink.general
    ) -> PairingCoordinator {
        let coordinator = PairingCoordinator(
            pair: { pairURL, deviceLabel, relayEndpoint in
                try await script.pair(pairURL: pairURL, deviceLabel: deviceLabel, relayEndpoint: relayEndpoint)
            },
            keychainStore: store,
            loadPairing: { try store.load() },
            savePairing: {
                onSave()
                try store.save($0)
            },
            reactivate: {
                reactivateStarted?.increment()
                await reactivateGate?.wait()
                await reactivate.record()
            },
            ownerState: { ownerState },
            relayEndpoint: { URL(string: "https://relay.test")! },
            deviceLabel: { "test mac" },
            clearLastSuccessfulJournalContact: { clear.record() },
            retireOwnCredential: retireOwnCredential,
            endSelfRetirement: endSelfRetirement,
            carriedPairingControl: carriedPairingControl,
            localPort: localPort,
            classifiedLog: classifiedLog
        )
        return coordinator
    }
}

private enum PairScriptError: Error, Sendable {
    case noOutcome
    case saveFailed
}

private struct PairCall: Sendable {
    let pairURL: PairURL
    let deviceLabel: String
    let relayEndpoint: URL
}

private enum PairScriptOutcome: Sendable {
    case success(StoredPairing)
    case failure(any Error & Sendable)
}

private actor PairScript {
    private var outcomes: [PairScriptOutcome]
    private(set) var calls: [PairCall] = []
    private let onPair: (@Sendable () async -> Void)?

    var callCount: Int {
        calls.count
    }

    init(_ outcomes: [PairScriptOutcome], onPair: (@Sendable () async -> Void)? = nil) {
        self.outcomes = outcomes
        self.onPair = onPair
    }

    func pair(pairURL: PairURL, deviceLabel: String, relayEndpoint: URL) async throws -> StoredPairing {
        calls.append(PairCall(pairURL: pairURL, deviceLabel: deviceLabel, relayEndpoint: relayEndpoint))
        await onPair?()
        guard !outcomes.isEmpty else {
            throw PairScriptError.noOutcome
        }
        switch outcomes.removeFirst() {
        case .success(let pairing):
            return pairing
        case .failure(let error):
            throw error
        }
    }
}

private actor ReactivateRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
private final class ClearRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] {
        lock.withLock { _events }
    }

    func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }
}

private func pairingWithFingerprint(_ fingerprint: String) -> StoredPairing {
    let original = pairing()
    return StoredPairing(
        instanceID: original.instanceID,
        homeLabel: original.homeLabel,
        relayEndpoint: original.relayEndpoint,
        fingerprint: fingerprint,
        clientCertPEM: original.clientCertPEM,
        clientKeyPEM: original.clientKeyPEM,
        caChainPEM: original.caChainPEM,
        relayEnrollment: original.relayEnrollment,
        localEndpoints: original.localEndpoints,
        pairedAt: original.pairedAt
    )
}

/// A fresh-pair decision persisted with the shown offer it answers.
func offeredRecord(with decision: CarriedPairingDecision) -> CarriedPairingRecord {
    var record = CarriedPairingRecord.empty
    record.replacementOfferID = decision.decisionID
    record.replacementOfferShown = true
    record.decision = decision
    return record
}

final class PairingControlScript: @unchecked Sendable {
    enum Mode: Sendable, Equatable {
        case unavailable
        case mismatchedTerminal
        case accepted
        case freshConflictAppliedReplay
        case freshConflictUnresolved
    }

    private let lock = NSLock()
    private let mode: Mode
    private let store: PairingStore
    private let clientsValue: [CarriedPairingClientRow]
    private let clientsGate: OneShotContinuationGate?
    private var clientsOutcomes: [(result: Result<[CarriedPairingClientRow], CarriedPairingControlError>, gate: OneShotContinuationGate?)] = []
    private let clientsStarted = LockedCounter()
    private let decisionGate: OneShotContinuationGate?
    private let decisionStarted = LockedCounter()
    private var eventValues: [String] = []
    private var durableDecision: CarriedPairingDecision?
    private var decisionValues: [CarriedPairingDecision?] = []
    private var decisionSubmissionCount = 0

    init(
        mode: Mode,
        store: PairingStore,
        clients: [CarriedPairingClientRow] = [],
        clientsGate: OneShotContinuationGate? = nil,
        decisionGate: OneShotContinuationGate? = nil
    ) {
        self.mode = mode
        self.store = store
        self.clientsValue = clients
        self.clientsGate = clientsGate
        self.decisionGate = decisionGate
    }

    var client: any CarriedPairingControlRequesting { PairingCoordinatorControlClient(script: self) }
    var events: [String] { lock.withLock { eventValues } }
    var decisionObservedAsDurable: CarriedPairingDecision? { lock.withLock { durableDecision } }
    var decisionSnapshots: [CarriedPairingDecision?] { lock.withLock { decisionValues } }

    func enqueueClientsOutcome(
        _ result: Result<[CarriedPairingClientRow], CarriedPairingControlError>,
        gate: OneShotContinuationGate? = nil
    ) {
        lock.withLock {
            clientsOutcomes.append((result: result, gate: gate))
        }
    }

    func migrationState() throws -> CarriedPairingMigrationReply {
        lock.withLock { eventValues.append("state") }
        let response: [String: Any] = [
            "protocol_version": 1,
            "rekey_operation_id": NSNull(),
            "previous_cid": NSNull(),
            "state": "none",
            "replaced_cid": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        return try JSONDecoder().decode(CarriedPairingMigrationReply.self, from: data)
    }

    func decide(_ decision: CarriedPairingDecision) throws -> CarriedPairingDecisionReply {
        let persisted = try store.loadCarriedPairingRecord().decision
        lock.withLock {
            eventValues.append("decide")
            durableDecision = persisted
            decisionValues.append(persisted)
            decisionSubmissionCount += 1
        }
        if case .unavailable = mode { throw CarriedPairingControlError.unavailable }
        if mode == .freshConflictAppliedReplay || mode == .freshConflictUnresolved {
            let count = lock.withLock { decisionSubmissionCount }
            if count == 1 || mode == .freshConflictUnresolved {
                throw CarriedPairingControlError.conflict
            }
        }

        let acceptedState: String
        switch decision.choice {
        case .newDevice: acceptedState = "new_device"
        case .replaceDevice: acceptedState = "replaced_device"
        }
        let state: String
        if case .mismatchedTerminal = mode {
            state = acceptedState == "new_device" ? "same_device" : "new_device"
        } else {
            state = acceptedState
        }
        let response: [String: Any] = [
            "protocol_version": 1,
            "operation_id": decision.decisionID,
            "state": state,
            "previous_cid": NSNull(),
            "cid": decision.credentialFingerprint,
            "replaced_cid": decision.replacesCID ?? NSNull(),
            "display_label": "Current device"
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        return try JSONDecoder().decode(CarriedPairingDecisionReply.self, from: data)
    }

    func waitBeforeDecisionReply() async {
        guard let decisionGate else { return }
        lock.withLock { eventValues.append("decision_waiting") }
        decisionStarted.increment()
        await decisionGate.wait()
    }

    func waitUntilDecisionStarts() async {
        await decisionStarted.waitUntilCount(1)
    }

    func clients() async throws -> [CarriedPairingClientRow] {
        let (outcome, gate) = lock.withLock { () -> (Result<[CarriedPairingClientRow], CarriedPairingControlError>?, OneShotContinuationGate?) in
            eventValues.append("clients")
            if !clientsOutcomes.isEmpty {
                let popped = clientsOutcomes.removeFirst()
                return (popped.result, popped.gate)
            }
            return (nil, clientsGate)
        }
        clientsStarted.increment()
        await gate?.wait()
        if let outcome {
            return try outcome.get()
        }
        return clientsValue
    }

    func waitUntilClientsStart(target: Int = 1) async {
        await clientsStarted.waitUntilCount(target)
    }
}

private struct PairingCoordinatorControlClient: CarriedPairingControlRequesting {
    let script: PairingControlScript

    func migrationState(localPort: Int) async throws -> CarriedPairingMigrationReply {
        try script.migrationState()
    }

    func decide(localPort: Int, decision: CarriedPairingDecision) async throws -> CarriedPairingDecisionReply {
        await script.waitBeforeDecisionReply()
        return try script.decide(decision)
    }

    func clients(localPort: Int) async throws -> [CarriedPairingClientRow] {
        try await script.clients()
    }
}

private let otherCACertPEM = """
-----BEGIN CERTIFICATE-----
MIIBezCCASGgAwIBAgIUUXhy5T/Oxx8wkpgCDLyi1q0iQFUwCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIb3RoZXJfY2EwHhcNMjYxMDAxMDIyNTM5WhcNMzYwOTI4MDIy
NTM5WjATMREwDwYDVQQDDAhvdGhlcl9jYTBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IABJufX4jGe/KcsaFIgTesuRAdmxUr0Y2ihzfbKB1nWHylxLwn/OQwEessZJMA
wDymX6GarVXHR4lC4Z4/Gu+OPPmjUzBRMB0GA1UdDgQWBBSlqU8IKW0/r2Mf5B1j
0foTix73PTAfBgNVHSMEGDAWgBSlqU8IKW0/r2Mf5B1j0foTix73PTAPBgNVHRMB
Af8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDQInd6YEfAv+IMYEjBvrnNBxSX
ctZztQYTMXclxfS4FAIgd/ROmt7eudqCvixG25cvL2sapUrplJ/UXGb/ooYGHCc=
-----END CERTIFICATE-----
"""

private enum TestCrockford32 {
    static func encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var accumulator: UInt64 = 0
        var bitCount = 0
        var output = ""

        for byte in bytes {
            accumulator = (accumulator << 8) | UInt64(byte)
            bitCount += 8

            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((accumulator >> UInt64(bitCount)) & 0x1f)
                output.append(alphabet[index])
                accumulator &= (1 << UInt64(bitCount)) - 1
            }
        }

        if bitCount > 0 {
            let index = Int((accumulator << UInt64(5 - bitCount)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }
}

private func directPairLink(caPEM: String) throws -> String {
    let certs = try CertChain.certificates(fromPEM: caPEM)
    let first = try #require(certs.first)
    let certData = SecCertificateCopyData(first) as Data
    let pinPrefix = Array(SHA256.hash(data: certData).prefix(16))
    var bytes = [UInt8](repeating: 0, count: 40)
    bytes[0] = 0x04
    bytes[1] = 0x01
    bytes[2] = 192
    bytes[3] = 168
    bytes[4] = 1
    bytes[5] = 42
    bytes[6] = 0x1b
    bytes[7] = 0x9e // 7070
    for i in 8..<24 {
        bytes[i] = UInt8(i)
    }
    bytes.replaceSubrange(24..<40, with: pinPrefix)
    return "https://go.solstone.app/p#\(TestCrockford32.encode(bytes))"
}

func relayPairLink(caPEM: String) throws -> String {
    let certs = try CertChain.certificates(fromPEM: caPEM)
    let first = try #require(certs.first)
    let spkiDER = try CertChain.canonicalP256SubjectPublicKeyInfoDER(certificate: first)
    let pinPrefix = Array(SHA256.hash(data: Data(spkiDER)).prefix(16))
    var bytes = [UInt8](repeating: 0, count: 27)
    bytes[0] = 0x06
    for i in 1..<9 {
        bytes[i] = 0x01
    }
    bytes[9] = 0x01
    bytes.replaceSubrange(10..<26, with: pinPrefix)
    bytes[26] = 0x00
    return "https://go.solstone.app/p#\(TestCrockford32.encode(bytes))"
}

// 0x04 direct: 192.168.1.42:7070.
private let directPairLink: String = {
    var bytes = [UInt8](repeating: 0, count: 40)
    bytes[0] = 0x04
    bytes[1] = 0x01
    bytes[2] = 192
    bytes[3] = 168
    bytes[4] = 1
    bytes[5] = 42
    bytes[6] = 0x1b
    bytes[7] = 0x9e // 7070
    for i in 8..<24 {
        bytes[i] = UInt8(i)
    }
    for i in 24..<40 {
        bytes[i] = UInt8(i)
    }
    return "https://go.solstone.app/p#\(TestCrockford32.encode(bytes))"
}()

// 0x05 direct: 10.0.0.7:7070, then 100.64.3.9:7070.
private let directMultiCandidatePairLink: String = {
    var bytes = [UInt8](repeating: 0, count: 45)
    bytes[0] = 0x05
    bytes[1] = 0x01
    bytes[2] = 0x02 // 2 candidates
    bytes[3] = 0x1b
    bytes[4] = 0x9e // port 7070
    // 10.0.0.7
    bytes[5] = 10
    bytes[6] = 0
    bytes[7] = 0
    bytes[8] = 7
    // 100.64.3.9
    bytes[9] = 100
    bytes[10] = 64
    bytes[11] = 3
    bytes[12] = 9
    // nonce 16 bytes
    for i in 13..<29 {
        bytes[i] = UInt8(i)
    }
    // caPin 16 bytes
    for i in 29..<45 {
        bytes[i] = UInt8(i)
    }
    return "https://go.solstone.app/p#\(TestCrockford32.encode(bytes))"
}()

private func relayPairLink(instanceID _: String) -> String {
    var bytes = [UInt8](repeating: 0, count: 27)
    bytes[0] = 0x06
    for i in 1..<9 {
        bytes[i] = 0x01
    }
    bytes[9] = 0x01
    for i in 10..<26 {
        bytes[i] = UInt8(i)
    }
    bytes[26] = 0x00
    return "https://go.solstone.app/p#\(TestCrockford32.encode(bytes))"
}
