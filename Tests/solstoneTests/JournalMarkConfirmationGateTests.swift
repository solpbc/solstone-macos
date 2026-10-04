// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import JournalMarkKit
import os
import SolstoneCore
import SPLTunnel
import Testing
@testable import solstone

/// Nothing this Mac captured goes to a journal until the owner confirms its mark.
@Suite("Journal mark confirmation gate", .serialized)
@MainActor
struct JournalMarkConfirmationGateTests {
    private let connected = TunnelLifecycleState.connected(localPort: 24680, via: .relay)
    private let identity = TunnelPairingIdentity(instanceID: "instance", fingerprint: "fingerprint")

    @Test func heldIsOnlyAConnectedUnansweredOwnerPairing() {
        #expect(AppState.needsJournalMarkConfirmation(
            tunnelManaged: true,
            lifecycleState: connected,
            adoptingAutomatically: false,
            journalIdentity: "journal",
            journalMarkConfirmed: false
        ))

        #expect(!AppState.needsJournalMarkConfirmation(
            tunnelManaged: true,
            lifecycleState: .disconnected,
            adoptingAutomatically: false,
            journalIdentity: "journal",
            journalMarkConfirmed: false
        ))
        #expect(!AppState.needsJournalMarkConfirmation(
            tunnelManaged: true,
            lifecycleState: .connecting,
            adoptingAutomatically: false,
            journalIdentity: "journal",
            journalMarkConfirmed: false
        ))
        #expect(!AppState.needsJournalMarkConfirmation(
            tunnelManaged: true,
            lifecycleState: .error(.revoked),
            adoptingAutomatically: false,
            journalIdentity: "journal",
            journalMarkConfirmed: false
        ))
        #expect(!AppState.needsJournalMarkConfirmation(
            tunnelManaged: true,
            lifecycleState: connected,
            adoptingAutomatically: false,
            journalIdentity: "journal",
            journalMarkConfirmed: true
        ))
        #expect(!AppState.needsJournalMarkConfirmation(
            tunnelManaged: true,
            lifecycleState: connected,
            adoptingAutomatically: true,
            journalIdentity: "journal",
            journalMarkConfirmed: false
        ))
        #expect(!AppState.needsJournalMarkConfirmation(
            tunnelManaged: false,
            lifecycleState: connected,
            adoptingAutomatically: false,
            journalIdentity: "journal",
            journalMarkConfirmed: false
        ))
        #expect(!AppState.needsJournalMarkConfirmation(
            tunnelManaged: true,
            lifecycleState: connected,
            adoptingAutomatically: false,
            journalIdentity: nil,
            journalMarkConfirmed: false
        ))
    }

    @Test func answeringOrClearingTheMarkIsObservable() {
        let answerState = AppState.forSnapshot(
            initialTunnelPairing: pairing(),
            journalMarkConfirmationStore: InMemoryJournalMarkConfirmationStore(settled: true)
        )
        let answerNotified = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = answerState.isJournalMarkConfirmed
        } onChange: {
            answerNotified.withLock { $0 = true }
        }
        answerState.recordJournalMarkConfirmed()
        #expect(answerNotified.withLock { $0 })

        let clearState = AppState.forSnapshot(
            initialTunnelPairing: pairing(),
            journalMarkConfirmationStore: InMemoryJournalMarkConfirmationStore(settled: true)
        )
        #expect(!clearState.isJournalMarkConfirmed)
        let clearNotified = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = clearState.isJournalMarkConfirmed
        } onChange: {
            clearNotified.withLock { $0 = true }
        }
        clearState.clearJournalMarkConfirmation()
        #expect(!clearState.isJournalMarkConfirmed)
        #expect(clearNotified.withLock { $0 })
    }

    @Test func readingAnUnsettledMarkDoesNotPublish() {
        let store = InMemoryJournalMarkConfirmationStore(settled: false)
        let state = AppState.forSnapshot(initialTunnelPairing: pairing(), journalMarkConfirmationStore: store)
        let notified = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            #expect(state.isJournalMarkConfirmed)
        } onChange: {
            notified.withLock { $0 = true }
        }
        #expect(store.settled)
        #expect(!notified.withLock { $0 })
    }

    @Test func heldLineShowsOnlyWhenHeldAndTheSheetIsDown() {
        #expect(SettingsView.journalMarkHeldLineVisible(needsJournalMarkConfirmation: true, markSheetPresented: false))
        #expect(!SettingsView.journalMarkHeldLineVisible(needsJournalMarkConfirmation: true, markSheetPresented: true))
        #expect(!SettingsView.journalMarkHeldLineVisible(needsJournalMarkConfirmation: false, markSheetPresented: false))
        #expect(!SettingsView.journalMarkHeldLineVisible(needsJournalMarkConfirmation: false, markSheetPresented: true))
    }

    @Test func ingestIsHeldOverAConnectedPairingUntilTheMarkIsConfirmed() {
        #expect(AppState.ingestBaseURL(
            lifecycleState: connected,
            localPort: 24680,
            pairingIdentity: identity,
            journalMarkConfirmed: false
        ) == .held)
        #expect(AppState.ingestBaseURL(
            lifecycleState: connected,
            localPort: 24680,
            pairingIdentity: identity,
            journalMarkConfirmed: true
        ) == .url("http://127.0.0.1:24680"))
    }

    @Test func aNewPairingWaitsForTheOwnersAnswer() {
        let store = InMemoryJournalMarkConfirmationStore(settled: true)
        let state = AppState.forSnapshot(initialTunnelPairing: pairing(), journalMarkConfirmationStore: store)

        #expect(!state.isJournalMarkConfirmed)
        #expect(!state.isPairedIngestReady)

        state.recordJournalMarkConfirmed()

        #expect(state.isJournalMarkConfirmed)
        #expect(store.confirmedJournal == journalMarkConfirmationIdentity(for: pairing()))
    }

    @Test func thePairingThisMacHeldBeforeKeepingAnswersCountsAsConfirmed() {
        let store = InMemoryJournalMarkConfirmationStore(settled: false)
        let state = AppState.forSnapshot(initialTunnelPairing: pairing(), journalMarkConfirmationStore: store)

        #expect(state.isJournalMarkConfirmed)
        #expect(store.settled)
    }

    @Test func noPairingIsNeverConfirmedAndSettlesNothing() {
        let store = InMemoryJournalMarkConfirmationStore(settled: false)
        let state = AppState.forSnapshot(journalMarkConfirmationStore: store)

        #expect(!state.isJournalMarkConfirmed)
        #expect(!store.settled)
    }

    @Test func theAnswerBelongsToOneJournal() {
        let answered = pairing(instanceID: "journal-a")
        let other = pairing(instanceID: "journal-b")
        let store = InMemoryJournalMarkConfirmationStore(
            confirmedJournal: journalMarkConfirmationIdentity(for: answered),
            settled: true
        )

        let sameJournal = AppState.forSnapshot(initialTunnelPairing: answered, journalMarkConfirmationStore: store)
        let otherJournal = AppState.forSnapshot(initialTunnelPairing: other, journalMarkConfirmationStore: store)

        #expect(sameJournal.isJournalMarkConfirmed)
        #expect(!otherJournal.isJournalMarkConfirmed)
    }

    @Test func pairingAgainWithTheSameJournalNamesTheSameJournal() {
        var repaired = pairing()
        repaired = StoredPairing(
            instanceID: repaired.instanceID,
            homeLabel: repaired.homeLabel,
            relayEndpoint: repaired.relayEndpoint,
            fingerprint: "another-device-certificate",
            clientCertPEM: "another-cert",
            clientKeyPEM: "another-key",
            caChainPEM: repaired.caChainPEM,
            relayEnrollment: repaired.relayEnrollment,
            localEndpoints: repaired.localEndpoints,
            pairedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(journalMarkConfirmationIdentity(for: repaired) == journalMarkConfirmationIdentity(for: pairing()))
        #expect(journalMarkConfirmationIdentity(for: pairing(instanceID: "journal-b")) != journalMarkConfirmationIdentity(for: pairing()))
    }

    @Test func confirmingAValidMarkRecordsTheAnswer() async throws {
        let store = InMemoryJournalMarkConfirmationStore(settled: true)
        let state = AppState.forSnapshot(initialTunnelPairing: pairing(), journalMarkConfirmationStore: store)
        let driver = JournalMarkConfirmationDriver(deadlineSeconds: 1)

        driver.confirm(appState: state)
        #expect(!state.isJournalMarkConfirmed)

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: { JournalMarkConfirmationDriver.HomeBaseResolution.url("http://127.0.0.1:7071") },
            fetchMark: { _ in .uiTestSample }
        )
        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run {
                if case .valid = driver.phase { return true }
                return false
            }
        }
        driver.continueAnyway(appState: state)
        #expect(!state.isJournalMarkConfirmed)

        driver.confirm(appState: state)
        #expect(state.isJournalMarkConfirmed)
    }

    @Test func continuingAfterACheckThatCouldNotFinishRecordsTheAnswer() async throws {
        let store = InMemoryJournalMarkConfirmationStore(settled: true)
        let state = AppState.forSnapshot(initialTunnelPairing: pairing(), journalMarkConfirmationStore: store)
        let driver = JournalMarkConfirmationDriver(deadlineSeconds: 0.05, heldPollInterval: .milliseconds(10))

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: { JournalMarkConfirmationDriver.HomeBaseResolution.held },
            fetchMark: { _ in nil }
        )
        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run {
                if case .unverified = driver.phase { return true }
                return false
            }
        }
        driver.confirm(appState: state)
        #expect(!state.isJournalMarkConfirmed)

        driver.continueAnyway(appState: state)
        #expect(state.isJournalMarkConfirmed)
    }

    @Test func aNewPairingClearsTheAnswerBeforeItsCredentialIsSaved() async {
        let events = GateEventLog()
        let store = PairingStore(pairing: nil)
        let coordinator = makeCoordinator(store: store, outcomes: [pairing()], events: events)

        await coordinator.submitPairingLink(gateRelayPairLink)

        #expect(coordinator.state == .paired)
        #expect(events.entries == ["clear", "save"])
    }

    @Test func aSwitchClearsTheAnswerBeforeItsCredentialIsSaved() async {
        let events = GateEventLog()
        let store = PairingStore(pairing: pairing(instanceID: "11111111-1111-1111-1111-111111111111"))
        let coordinator = makeCoordinator(
            store: store,
            outcomes: [pairing(instanceID: "22222222-2222-2222-2222-222222222222")],
            events: events
        )

        await coordinator.submitPairingLink(gateRelayPairLink)
        #expect(events.entries.isEmpty)
        await coordinator.confirmSwitch()

        #expect(coordinator.state == .switched)
        #expect(events.entries == ["clear", "save"])
    }

    @Test func pairingAgainWithTheSameJournalKeepsTheAnswer() async throws {
        let events = GateEventLog()
        let instanceID = "11111111-1111-1111-1111-111111111111"
        let store = PairingStore(pairing: pairing(instanceID: instanceID))
        let coordinator = makeCoordinator(store: store, outcomes: [pairing(instanceID: instanceID)], events: events)

        // Same journal is the CA pin on the link, not the instance id.
        await coordinator.submitPairingLink(try relayPairLink(caPEM: testCACertPEM))

        #expect(coordinator.state == .alreadyConnected)
        #expect(events.entries == ["save"])
    }

    @Test func unpairingClearsTheAnswer() async {
        let events = GateEventLog()
        let coordinator = makeCoordinator(store: PairingStore(pairing: pairing()), outcomes: [], events: events)

        await coordinator.unpair()

        #expect(events.entries == ["clear"])
    }

    private func makeCoordinator(
        store: PairingStore,
        outcomes: [StoredPairing],
        events: GateEventLog
    ) -> PairingCoordinator {
        let remaining = GateOutcomes(outcomes)
        let coordinator = PairingCoordinator(
            pair: { _, _, _ in try await remaining.next() },
            loadPairing: { try store.load() },
            savePairing: { pairing in
                events.record("save")
                try store.save(pairing)
            },
            deletePairing: { try store.delete() },
            relayEndpoint: { URL(string: "https://relay.test")! },
            deviceLabel: { "test mac" },
            clearJournalMarkConfirmation: { events.record("clear") }
        )
        return coordinator
    }
}

private final class GateEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var entries: [String] { lock.withLock { recorded } }

    func record(_ entry: String) {
        lock.withLock { recorded.append(entry) }
    }
}

private actor GateOutcomes {
    private var outcomes: [StoredPairing]

    init(_ outcomes: [StoredPairing]) {
        self.outcomes = outcomes
    }

    func next() throws -> StoredPairing {
        guard !outcomes.isEmpty else { throw CancellationError() }
        return outcomes.removeFirst()
    }
}

// The same relay link the coordinator tests use; the scripted ceremony ignores its contents.
private let gateRelayPairLink = "https://go.solstone.app/p#0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00"

@Suite("Journal window waits for the mark answer")
@MainActor
struct JournalWindowMarkGateTests {
    @Test func theJournalWindowIsHeldOverAPairingUntilTheMarkIsConfirmed() {
        let live = ResolvedHomeBase.url("http://127.0.0.1:24680")

        #expect(AppState.journalWindowBase(
            homeBase: live, tunnelManaged: true, pairingHeld: true, journalMarkConfirmed: false
        ) == .held)
        #expect(AppState.journalWindowBase(
            homeBase: live, tunnelManaged: true, pairingHeld: true, journalMarkConfirmed: true
        ) == live)
        #expect(AppState.journalWindowBase(
            homeBase: .url("https://journal.example"), tunnelManaged: false, pairingHeld: false, journalMarkConfirmed: false
        ) == .url("https://journal.example"))
    }
}
