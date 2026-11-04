// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import ServiceManagement
import SolstoneCore
import SPLTunnel
import Testing
@testable import solstone

/// "this is your journal" is only for an answer that came from matching a mark.
@Suite("Journal mark comparison", .serialized)
@MainActor
struct JournalMarkComparisonTests {
    private final class LoginItems: LoginItemService {
        var watchdogStatus: SMAppService.Status { .notRegistered }
        var mainAppStatus: SMAppService.Status { .notRegistered }
        func registerWatchdog() throws {}
        func unregisterWatchdog() throws {}
        func unregisterWatchdogAwaitingCompletion() async throws {}
        func unregisterMainApp() throws {}
    }

    private let stored = pairing(
        instanceID: "11111111-1111-1111-1111-111111111111",
        caChainPEM: testCACertPEM,
        fingerprint: "stored-fingerprint"
    )
    private let replacement = pairing(
        instanceID: "22222222-2222-2222-2222-222222222222",
        caChainPEM: otherCACertPEM,
        fingerprint: "new-fingerprint"
    )

    private func makeState(
        store: PairingStore,
        answers: any JournalMarkConfirmationStoring,
        pairingOutcome: StoredPairing? = nil
    ) -> AppState {
        let outcome = pairingOutcome
        return AppState.forLoginItemTest(
            loginService: LoginItems(),
            pairingStoring: store,
            pairingOperation: { _, _, _ in
                guard let outcome else { throw PairError.nonceExpired }
                return outcome
            },
            pairingLoad: { try store.load() },
            pairingSave: { try store.save($0) },
            journalMarkConfirmationStore: answers
        )
    }

    /// The first attempt can't draw a mark; the owner continues; a later read can.
    private func continueAnyway(on state: AppState) async throws {
        state.journalMarkDeriver = { _ in nil }
        let driver = JournalMarkConfirmationDriver()
        driver.startIfNeeded(for: .paired, deriveMark: { await state.markForAnswer() })
        try await waitUntil(timeout: .seconds(5)) { @MainActor in driver.phase == .unverified }
        await driver.continueAnyway(appState: state)?.value
        #expect(!driver.isPresented)
        #expect(state.isJournalMarkConfirmed)
    }

    @Test func aLaterReadAfterContinueAnywayDoesNotClaimAComparison() async throws {
        let store = PairingStore(pairing: stored)
        let answers = InMemoryJournalMarkConfirmationStore()
        let state = makeState(store: store, answers: answers)
        try await continueAnyway(on: state)

        state.journalMarkDeriver = { _ in JournalMark.uiTestSample }
        await state.deriveConfirmedMark()

        #expect(state.confirmedMark == JournalMark.uiTestSample)
        #expect(state.isJournalMarkConfirmed)
        #expect(!state.isJournalMarkCompared)
    }

    @Test func aComparisonSaysSoAndRelaunchingKeepsEitherAnswer() async throws {
        let suite = "journal-mark-comparison-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairingStore(pairing: stored)
        let journal = journalMarkConfirmationIdentity(for: stored)

        let first = UserDefaultsJournalMarkConfirmationStore(defaults: defaults)
        first.confirmWithoutComparison(journal)
        let relaunched = UserDefaultsJournalMarkConfirmationStore(defaults: defaults)
        #expect(relaunched.confirmedJournal == journal)
        #expect(relaunched.uncomparedJournal == journal)
        let afterContinue = makeState(store: store, answers: relaunched)
        #expect(afterContinue.isJournalMarkConfirmed)
        #expect(!afterContinue.isJournalMarkCompared)

        relaunched.confirm(journal)
        #expect(UserDefaultsJournalMarkConfirmationStore(defaults: defaults).uncomparedJournal == nil)
        let afterMatch = makeState(store: store, answers: relaunched)
        #expect(afterMatch.isJournalMarkCompared)
    }

    @Test func clearingEndsTheUncomparedAnswerToo() throws {
        let suite = "journal-mark-comparison-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let answers = UserDefaultsJournalMarkConfirmationStore(defaults: defaults)
        answers.confirmWithoutComparison("journal")
        answers.clear()

        #expect(answers.confirmedJournal == nil)
        #expect(answers.uncomparedJournal == nil)
    }

    @Test func anUncomparedAnswerForAnotherJournalDoesNotReachThisOne() {
        let store = PairingStore(pairing: stored)
        let answers = InMemoryJournalMarkConfirmationStore()
        answers.confirmWithoutComparison("another journal")
        answers.confirm(journalMarkConfirmationIdentity(for: stored))
        #expect(makeState(store: store, answers: answers).isJournalMarkCompared)
    }

    @Test func aHeldSwitchContinuedWithoutAMarkDoesNotClaimAComparison() async throws {
        let store = PairingStore(pairing: stored)
        let answers = InMemoryJournalMarkConfirmationStore(
            confirmedJournal: journalMarkConfirmationIdentity(for: stored)
        )
        let state = makeState(store: store, answers: answers, pairingOutcome: replacement)
        state.heldSwitchMarkDeriver = { _ in nil }
        state.journalMarkDeriver = { _ in JournalMark.uiTestSample }
        #expect(state.isJournalMarkCompared)

        await state.pairingCoordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await state.pairingCoordinator.confirmSwitch()
        let driver = JournalMarkConfirmationDriver()
        driver.startIfNeeded(for: .switchMarkPending, appState: state)
        try await waitUntil(timeout: .seconds(2)) { @MainActor in driver.phase == .unverified }
        await driver.continueAnyway(appState: state)?.value

        let journal = journalMarkConfirmationIdentity(for: replacement)
        #expect(store.currentPairing == replacement)
        #expect(answers.confirmedJournal == journal)
        #expect(answers.uncomparedJournal == journal)
        #expect(!state.isJournalMarkCompared)

        await state.deriveConfirmedMark()
        #expect(state.confirmedMark == JournalMark.uiTestSample)
        #expect(!state.isJournalMarkCompared)
    }

    @Test func aHeldSwitchAnsweredYesSaysSo() async throws {
        let store = PairingStore(pairing: stored)
        let answers = InMemoryJournalMarkConfirmationStore()
        answers.confirmWithoutComparison(journalMarkConfirmationIdentity(for: stored))
        let state = makeState(store: store, answers: answers, pairingOutcome: replacement)
        state.heldSwitchMarkDeriver = { _ in JournalMark.uiTestSample }

        await state.pairingCoordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        await state.pairingCoordinator.confirmSwitch()
        let driver = JournalMarkConfirmationDriver()
        driver.startIfNeeded(for: .switchMarkPending, appState: state)
        try await waitUntil(timeout: .seconds(2)) { @MainActor in driver.phase != .deriving }
        await driver.confirm(appState: state)?.value

        #expect(store.currentPairing == replacement)
        #expect(answers.uncomparedJournal == nil)
        #expect(state.isJournalMarkCompared)
    }
}
