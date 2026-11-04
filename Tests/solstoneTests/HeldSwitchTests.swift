// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import SolstoneCore
import SPLMark
import ServiceManagement
import SPLTunnel
import Testing
@testable import solstone

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var retiredPairings: [StoredPairing] = []
    var entries: [String] { lock.withLock { recorded } }
    var retired: [StoredPairing] { lock.withLock { retiredPairings } }
    func record(_ entry: String) { lock.withLock { recorded.append(entry) } }
    func retire(_ pairing: StoredPairing) {
        lock.withLock {
            recorded.append("retire")
            retiredPairings.append(pairing)
        }
    }
}

private let priorPairing = pairing(
    instanceID: "11111111-1111-1111-1111-111111111111",
    caChainPEM: testCACertPEM,
    fingerprint: "prior-fingerprint"
)
private let newPairing = pairing(
    instanceID: "22222222-2222-2222-2222-222222222222",
    caChainPEM: otherCACertPEM,
    fingerprint: "new-fingerprint"
)

/// A switch keeps the old pairing until the new mark is answered.
@Suite("Held switch: coordinator", .serialized)
@MainActor
struct HeldSwitchCoordinatorTests {
    private func makeCoordinator(
        store: PairingStore,
        outcomes: [StoredPairing],
        calls: Calls,
        asks: Bool = true
    ) -> PairingCoordinator {
        let remaining = OutcomeQueue(outcomes)
        return PairingCoordinator(
            pair: { _, _, _ in try await remaining.next() },
            keychainStore: store,
            loadPairing: { try store.load() },
            savePairing: { pairing in
                calls.record("save")
                try store.save(pairing)
            },
            reactivate: { calls.record("reactivate") },
            relayEndpoint: { URL(string: "https://relay.test")! },
            deviceLabel: { "test mac" },
            clearJournalMarkConfirmation: { calls.record("clear") },
            retireOwnCredential: { pairing, _ in
                calls.retire(pairing)
                return true
            },
            switchAsksMark: { asks }
        )
    }

    private func hold(
        store: PairingStore = PairingStore(pairing: priorPairing),
        outcomes: [StoredPairing] = [newPairing],
        calls: Calls = Calls()
    ) async throws -> (PairingCoordinator, PairingStore, Calls, UUID) {
        let coordinator = makeCoordinator(store: store, outcomes: outcomes, calls: calls)
        await coordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await coordinator.confirmSwitch()
        let attempt = try #require(coordinator.heldSwitch?.attempt)
        return (coordinator, store, calls, attempt)
    }

    private func expectUnchanged(_ store: PairingStore, _ calls: Calls) throws {
        #expect(store.currentPairing == priorPairing)
        #expect(store.saveCount == 0)
        #expect(!store.deleted)
        #expect(calls.retired.isEmpty)
        #expect(calls.entries.isEmpty)
        #expect(try store.loadCarriedPairingRecord().invalidation == nil)
    }

    @Test func theCeremonyHoldsTheNewPairingAndTouchesNothing() async throws {
        let (coordinator, store, calls, _) = try await hold()

        #expect(coordinator.state == .switchMarkPending)
        #expect(coordinator.heldSwitch?.pairing == newPairing)
        try expectUnchanged(store, calls)
    }

    @Test func yesRetiresTheOldPairingThenActivatesTheHeldOne() async throws {
        let (coordinator, store, calls, attempt) = try await hold()

        await coordinator.commitHeldSwitch(attempt: attempt) { pairing in
            #expect(pairing == newPairing)
            calls.record("answer")
        }

        #expect(coordinator.state == .switched)
        #expect(coordinator.heldSwitch == nil)
        #expect(store.currentPairing == newPairing)
        #expect(store.savedPairings == [newPairing])
        #expect(calls.retired == [priorPairing])
        // The answer lands with the credential, before the new pairing starts being used.
        #expect(calls.entries == ["retire", "clear", "answer", "reactivate"])
    }

    @Test func noDropsTheHeldPairingAndRetiresNothing() async throws {
        let (coordinator, store, calls, attempt) = try await hold()

        #expect(coordinator.declineHeldSwitch(attempt: attempt))

        #expect(coordinator.state == .switchDeclined)
        #expect(coordinator.heldSwitch == nil)
        try expectUnchanged(store, calls)
    }

    @Test func aPairingDeclinedCanNeverActivateLater() async throws {
        let (coordinator, store, calls, attempt) = try await hold()
        coordinator.declineHeldSwitch(attempt: attempt)

        await coordinator.commitHeldSwitch(attempt: attempt) { _ in calls.record("answer") }
        await coordinator.confirmSwitch()

        #expect(coordinator.state == .switchDeclined)
        try expectUnchanged(store, calls)
    }

    @Test func anAnswerForAnotherAttemptDoesNothing() async throws {
        let (coordinator, store, calls, attempt) = try await hold()

        await coordinator.commitHeldSwitch(attempt: UUID()) { _ in calls.record("answer") }
        #expect(!coordinator.declineHeldSwitch(attempt: UUID()))

        #expect(coordinator.state == .switchMarkPending)
        #expect(coordinator.heldSwitch?.attempt == attempt)
        try expectUnchanged(store, calls)
    }

    @Test func aYesForAnEarlierHoldCommitsNeitherPairing() async throws {
        let later = pairing(
            instanceID: "33333333-3333-3333-3333-333333333333",
            caChainPEM: otherCACertPEM,
            fingerprint: "later-fingerprint"
        )
        let (coordinator, store, calls, earlier) = try await hold(outcomes: [newPairing, later])

        await coordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await coordinator.confirmSwitch()
        let current = try #require(coordinator.heldSwitch)
        #expect(current.pairing == later)

        await coordinator.commitHeldSwitch(attempt: earlier) { _ in calls.record("answer") }
        try expectUnchanged(store, calls)

        await coordinator.commitHeldSwitch(attempt: current.attempt) { pairing in
            #expect(pairing == later)
        }
        #expect(store.currentPairing == later)
    }

    @Test func abandoningAnotherAttemptLeavesTheHeldPairing() async throws {
        let (coordinator, store, calls, attempt) = try await hold()

        coordinator.abandonHeldSwitch(attempt: UUID())
        coordinator.abandonHeldSwitch(attempt: nil)

        #expect(coordinator.state == .switchMarkPending)
        #expect(coordinator.heldSwitch?.attempt == attempt)
        try expectUnchanged(store, calls)
    }

    @Test func notChangedEndsWhenSettingsCloses() async throws {
        let (coordinator, store, calls, attempt) = try await hold()
        coordinator.clearSwitchDeclined()
        #expect(coordinator.state == .switchMarkPending)

        coordinator.declineHeldSwitch(attempt: attempt)
        coordinator.clearSwitchDeclined()

        #expect(coordinator.state == .idle)
        try expectUnchanged(store, calls)
    }

    @Test func yesAfterTheOldPairingWentAwayStillActivatesTheHeldOne() async throws {
        let (coordinator, store, calls, attempt) = try await hold()
        try store.delete()

        await coordinator.commitHeldSwitch(attempt: attempt) { pairing in
            #expect(pairing == newPairing)
            calls.record("answer")
        }

        #expect(coordinator.state == .switched)
        #expect(store.currentPairing == newPairing)
        #expect(calls.retired.isEmpty)
        #expect(calls.entries == ["save", "clear", "answer", "reactivate"])
    }

    @Test func aPathThatDoesNotAskStillFailsWithNothingStored() async throws {
        let store = PairingStore(pairing: priorPairing)
        let coordinator = makeCoordinator(store: store, outcomes: [newPairing], calls: Calls(), asks: false)
        await coordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        try store.delete()

        await coordinator.confirmSwitch()

        #expect(coordinator.state == .failed(.localSetup))
        #expect(store.currentPairing == nil)
    }

    @Test func closingTheQuestionLeavesTheOldPairing() async throws {
        let (coordinator, store, calls, attempt) = try await hold()

        coordinator.abandonHeldSwitch(attempt: attempt)

        #expect(coordinator.state == .idle)
        #expect(coordinator.heldSwitch == nil)
        await coordinator.commitHeldSwitch(attempt: attempt) { _ in calls.record("answer") }
        try expectUnchanged(store, calls)
    }

    @Test func quittingDuringTheQuestionPersistsNothing() async throws {
        let (_, store, calls, _) = try await hold()

        // A later launch sees only what was stored.
        let relaunched = makeCoordinator(store: store, outcomes: [], calls: Calls())

        #expect(relaunched.state == .idle)
        #expect(relaunched.heldSwitch == nil)
        await relaunched.recoverDurableInvalidation()
        #expect(relaunched.state == .idle)
        try expectUnchanged(store, calls)
    }

    @Test func anyOtherStateDropsTheHeldPairing() async throws {
        let (coordinator, store, calls, attempt) = try await hold()

        coordinator.recordInvalidLink(reason: "bad")

        #expect(coordinator.heldSwitch == nil)
        await coordinator.commitHeldSwitch(attempt: attempt) { _ in calls.record("answer") }
        try expectUnchanged(store, calls)
    }

    @Test func unpairingDuringTheQuestionRetiresOnlyTheStoredPairing() async throws {
        let (coordinator, store, calls, attempt) = try await hold()

        #expect(await coordinator.unpair())
        await coordinator.commitHeldSwitch(attempt: attempt) { _ in calls.record("answer") }

        #expect(calls.retired == [priorPairing])
        #expect(store.currentPairing == nil)
        #expect(!calls.entries.contains("answer"))
    }

    @Test func aFailedCeremonyHoldsNothing() async throws {
        let store = PairingStore(pairing: priorPairing)
        let calls = Calls()
        let coordinator = makeCoordinator(store: store, outcomes: [], calls: calls)

        await coordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await coordinator.confirmSwitch()

        #expect(coordinator.heldSwitch == nil)
        if case .failed = coordinator.state {} else { Issue.record("expected a failed state") }
        try expectUnchanged(store, calls)
    }

    @Test func aPathThatDoesNotAskCommitsAtOnce() async throws {
        let store = PairingStore(pairing: priorPairing)
        let calls = Calls()
        let coordinator = makeCoordinator(store: store, outcomes: [newPairing], calls: calls, asks: false)

        await coordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await coordinator.confirmSwitch()

        #expect(coordinator.state == .switched)
        #expect(coordinator.heldSwitch == nil)
        #expect(store.currentPairing == newPairing)
        #expect(calls.retired == [priorPairing])
    }

    @Test func aFirstPairingAndASameJournalRotationHoldNothing() async throws {
        let empty = PairingStore(pairing: nil)
        let first = makeCoordinator(store: empty, outcomes: [priorPairing], calls: Calls())
        await first.submitPairingLink(try relayPairLink(caPEM: testCACertPEM))
        #expect(first.state == .paired)
        #expect(first.heldSwitch == nil)
        #expect(empty.currentPairing == priorPairing)

        let rotated = pairing(
            instanceID: priorPairing.instanceID,
            caChainPEM: testCACertPEM,
            fingerprint: "rotated-fingerprint"
        )
        let held = PairingStore(pairing: priorPairing)
        let rotation = makeCoordinator(store: held, outcomes: [rotated], calls: Calls())
        await rotation.submitPairingLink(try relayPairLink(caPEM: testCACertPEM))
        #expect(rotation.state == .alreadyConnected)
        #expect(rotation.heldSwitch == nil)
        #expect(held.currentPairing == rotated)
    }
}

/// The same flow through the sheet's driver: an answer follows the question it was asked about.
@Suite("Held switch: driver", .serialized)
@MainActor
struct HeldSwitchDriverTests {
    private struct World {
        let state: AppState
        let store: PairingStore
        let answers: InMemoryJournalMarkConfirmationStore
        let calls: Calls
        let driver: JournalMarkConfirmationDriver
    }

    private let heldMark = JournalMark.uiTestSample
    private let priorIdentity = journalMarkConfirmationIdentity(for: priorPairing)
    private let newIdentity = journalMarkConfirmationIdentity(for: newPairing)

    private func makeWorld(heldMark: JournalMark?) async throws -> World {
        let store = PairingStore(pairing: priorPairing)
        let calls = Calls()
        let answers = InMemoryJournalMarkConfirmationStore(
            confirmedJournal: journalMarkConfirmationIdentity(for: priorPairing)
        )
        let state = AppState.forLoginItemTest(
            loginService: HeldSwitchLoginItems(),
            pairingStoring: store,
            pairingOperation: { _, _, _ in newPairing },
            pairingRetire: { pairing, _ in
                calls.retire(pairing)
                return true
            },
            pairingLoad: { try store.load() },
            pairingSave: { try store.save($0) },
            journalMarkConfirmationStore: answers
        )
        let deriverSeen = heldMark
        state.heldSwitchMarkDeriver = { pairing in
            calls.record("derived:\(pairing.instanceID)")
            return deriverSeen
        }
        return World(state: state, store: store, answers: answers, calls: calls, driver: JournalMarkConfirmationDriver())
    }

    /// Runs to the open question and returns once its phase has settled.
    private func ask(_ world: World) async throws {
        await world.state.pairingCoordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await world.state.pairingCoordinator.confirmSwitch()
        world.driver.startIfNeeded(for: world.state.pairingCoordinator.state, appState: world.state)
        try await waitUntil(timeout: .seconds(2)) { @MainActor [driver = world.driver] in
            driver.phase != .deriving
        }
    }

    private func expectOldPairingStays(_ world: World) throws {
        #expect(world.store.currentPairing == priorPairing)
        #expect(world.store.saveCount == 0)
        #expect(!world.store.deleted)
        #expect(world.calls.retired.isEmpty)
        #expect(world.answers.confirmedJournal == priorIdentity)
        #expect(try world.store.loadCarriedPairingRecord().invalidation == nil)
    }

    private func expectNewPairingCommitted(_ world: World) {
        #expect(world.state.pairingCoordinator.state == .switched)
        #expect(world.store.currentPairing == newPairing)
        #expect(world.calls.retired == [priorPairing])
        #expect(world.answers.confirmedJournal == newIdentity)
        #expect(!world.driver.isPresented)
    }

    @Test func theMarkIsAskedFromTheHeldPairingBeforeAnythingChanges() async throws {
        let world = try await makeWorld(heldMark: heldMark)
        try await ask(world)

        #expect(world.driver.isPresented)
        #expect(world.driver.phase == .valid(heldMark))
        #expect(world.calls.entries == ["derived:\(newPairing.instanceID)"])
        try expectOldPairingStays(world)
        world.driver.cancel()
    }

    @Test func yesCommitsTheHeldPairingAndIsNotAskedAgain() async throws {
        let world = try await makeWorld(heldMark: heldMark)
        try await ask(world)

        await world.driver.confirm(appState: world.state)?.value

        expectNewPairingCommitted(world)
        #expect(world.state.confirmedMark == heldMark)

        world.driver.startIfNeeded(for: .switched, appState: world.state)
        world.driver.startIfUnconfirmed(appState: world.state)
        #expect(!world.driver.isPresented)
    }

    @Test func noKeepsTheOldPairingAndItsCredential() async throws {
        let world = try await makeWorld(heldMark: heldMark)
        try await ask(world)
        var mismatch = false

        #expect(await world.driver.reject(appState: world.state) { mismatch = true })

        #expect(world.state.pairingCoordinator.state == .switchDeclined)
        #expect(!mismatch)
        #expect(!world.driver.isPresented)
        try expectOldPairingStays(world)
    }

    @Test func continueAnywayBehavesLikeYes() async throws {
        let world = try await makeWorld(heldMark: nil)
        try await ask(world)
        #expect(world.driver.phase == .unverified)
        try expectOldPairingStays(world)

        await world.driver.continueAnyway(appState: world.state)?.value

        expectNewPairingCommitted(world)
        #expect(world.state.confirmedMark == nil)
    }

    @Test func cancelBehavesLikeNo() async throws {
        let world = try await makeWorld(heldMark: nil)
        try await ask(world)
        #expect(world.driver.phase == .unverified)

        #expect(await world.driver.cancelPairing(appState: world.state))

        #expect(world.state.pairingCoordinator.state == .switchDeclined)
        #expect(!world.driver.isPresented)
        try expectOldPairingStays(world)
    }

    @Test func aStaleSheetsYesNeverTouchesEitherPairing() async throws {
        let world = try await makeWorld(heldMark: heldMark)
        try await ask(world)

        // The question ended while the sheet still drew its mark.
        world.state.pairingCoordinator.abandonHeldSwitch(attempt: world.driver.heldSwitchAttempt)
        await world.driver.confirm(appState: world.state)?.value

        #expect(world.state.pairingCoordinator.state == .idle)
        try expectOldPairingStays(world)
    }

    @Test func closingTheQuestionDropsItsOwnHeldPairing() async throws {
        let world = try await makeWorld(heldMark: heldMark)
        try await ask(world)

        world.driver.closeQuestion(appState: world.state)

        #expect(world.state.pairingCoordinator.state == .idle)
        #expect(!world.driver.isPresented)
        try expectOldPairingStays(world)
    }

    @Test func aFinishedSheetsDismissalLeavesALaterHoldAlone() async throws {
        let world = try await makeWorld(heldMark: heldMark)
        try await ask(world)
        let first = try #require(world.driver.heldSwitchAttempt)
        _ = await world.driver.reject(appState: world.state) {}

        // A second switch reaches its question before the first sheet's dismissal arrives.
        await world.state.pairingCoordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        world.driver.startIfNeeded(for: world.state.pairingCoordinator.state, appState: world.state)
        await world.state.pairingCoordinator.confirmSwitch()
        let second = try #require(world.state.pairingCoordinator.heldSwitch?.attempt)
        #expect(second != first)

        // Nothing on screen yet: the hold stays for its own question.
        world.driver.sheetDismissed()
        world.driver.closeQuestion(appState: world.state)
        #expect(world.state.pairingCoordinator.heldSwitch?.attempt == second)

        // Its question open: the late dismissal leaves that too.
        world.driver.startIfNeeded(for: .switchMarkPending, appState: world.state)
        world.driver.sheetDismissed()
        #expect(world.driver.isPresented)
        #expect(world.driver.heldSwitchAttempt == second)
        #expect(world.state.pairingCoordinator.heldSwitch?.attempt == second)
        try expectOldPairingStays(world)
        world.driver.cancel()
    }

    @Test func aSaveThatFailsAfterTheOldPairingRetiredDropsItsMark() async throws {
        let tempDir = URL(fileURLWithPath: "/var/tmp/solstone-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = FileBackedPairingStore(directory: tempDir)
        try store.save(priorPairing)
        store.failNextCredentialSave = true
        let answers = InMemoryJournalMarkConfirmationStore(confirmedJournal: priorIdentity)
        let state = AppState.forLoginItemTest(
            loginService: HeldSwitchLoginItems(),
            pairingStoring: store,
            pairingOperation: { _, _, _ in newPairing },
            pairingLoad: { try store.load() },
            journalMarkConfirmationStore: answers
        )
        state.heldSwitchMarkDeriver = { [heldMark] _ in heldMark }
        let oldMark = JournalMark(icon1: heldMark.icon2, icon2: heldMark.icon1, words: ["kept", "mark"])
        state.setConfirmedMark(oldMark)
        let driver = JournalMarkConfirmationDriver()
        await state.pairingCoordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await state.pairingCoordinator.confirmSwitch()
        driver.startIfNeeded(for: .switchMarkPending, appState: state)
        try await waitUntil(timeout: .seconds(2)) { @MainActor in driver.phase != .deriving }

        await driver.confirm(appState: state)?.value

        #expect(state.pairingCoordinator.state == .saveFailed)
        #expect(state.pairingCoordinator.hasOpenInvalidation)
        #expect(state.confirmedMark == nil)
    }

    @Test func leavingTheQuestionsStateClosesItsSheet() async throws {
        let world = try await makeWorld(heldMark: heldMark)
        try await ask(world)

        world.state.pairingCoordinator.abandonHeldSwitch(attempt: world.driver.heldSwitchAttempt)
        world.driver.startIfNeeded(for: world.state.pairingCoordinator.state, appState: world.state)

        #expect(!world.driver.isPresented)
        try expectOldPairingStays(world)
    }

    @Test func aSameComputerLinkAndTheAutomaticAdoptionCommitAtOnce() async throws {
        let sameComputer = try await makeWorld(heldMark: heldMark)
        await sameComputer.state.pairingCoordinator.submitPairingLink(
            try relayPairLink(caPEM: otherCACertPEM),
            sameComputer: true
        )
        await sameComputer.state.pairingCoordinator.confirmSwitch()
        #expect(sameComputer.state.pairingCoordinator.state == .switched)
        #expect(sameComputer.store.currentPairing == newPairing)
        #expect(sameComputer.calls.retired == [priorPairing])

        let adopting = try await makeWorld(heldMark: heldMark)
        adopting.state.isAdoptingSameMachineHomeAutomatically = true
        await adopting.state.pairingCoordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await adopting.state.pairingCoordinator.confirmSwitch()
        #expect(adopting.state.pairingCoordinator.state == .switched)
        #expect(adopting.store.currentPairing == newPairing)
    }

    @Test func theOldMarkStaysOnScreenThroughADeclinedSwitch() async throws {
        let world = try await makeWorld(heldMark: heldMark)
        let oldMark = JournalMark(
            icon1: heldMark.icon2,
            icon2: heldMark.icon1,
            words: ["kept", "mark"]
        )
        world.state.journalMarkDeriver = { pairing in
            #expect(pairing == priorPairing)
            return oldMark
        }
        world.state.setConfirmedMark(oldMark)

        // Owner-started link: the mark is cleared on the way in, and comes back for the old pairing.
        await world.state.submitPairingInput(try relayPairLink(caPEM: otherCACertPEM))
        #expect(world.state.pairingCoordinator.state == .switchConfirmPending)
        await world.state.pairingCoordinator.confirmSwitch()
        world.driver.startIfNeeded(for: world.state.pairingCoordinator.state, appState: world.state)
        try await waitUntil(timeout: .seconds(2)) { @MainActor [driver = world.driver] in
            driver.phase != .deriving
        }
        _ = await world.driver.reject(appState: world.state) {}

        #expect(world.state.confirmedMark == oldMark)
        try expectOldPairingStays(world)
    }

    @Test func aHeldMarkIsWorkedOutFromItsOwnCAAndKeepsNothing() async throws {
        let suite = "held-switch-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let kept = DerivedJournalMarkStore(suiteName: suite)
        let priorID = try CertChain.journalID(ofCAChainPEM: testCACertPEM)
        kept.save(JournalMark.uiTestSample, journalID: priorID)

        let seen = Calls()
        let mark = await JournalMarkDerivation.markKeepingNothing(forCAChainPEM: otherCACertPEM) { journalID in
            seen.record(journalID)
            return try markFromJournalID(journalID)
        }

        #expect(mark != nil)
        #expect(seen.entries == [try CertChain.journalID(ofCAChainPEM: otherCACertPEM)])
        #expect(kept.mark(forJournalID: priorID) == JournalMark.uiTestSample)
    }
}

private final class HeldSwitchLoginItems: LoginItemService {
    var watchdogStatus: SMAppService.Status { .notRegistered }
    var mainAppStatus: SMAppService.Status { .notRegistered }
    func registerWatchdog() throws {}
    func unregisterWatchdog() throws {}
    func unregisterWatchdogAwaitingCompletion() async throws {}
    func unregisterMainApp() throws {}
}

private actor OutcomeQueue {
    private var outcomes: [StoredPairing]

    init(_ outcomes: [StoredPairing]) {
        self.outcomes = outcomes
    }

    func next() throws -> StoredPairing {
        guard !outcomes.isEmpty else { throw PairError.nonceExpired }
        return outcomes.removeFirst()
    }
}
