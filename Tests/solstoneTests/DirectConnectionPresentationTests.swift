// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("DirectConnectionPresentation")
struct DirectConnectionPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func noOutcomeYetReadsConnecting() {
        let p = makeDirectConnectionPresentation(outcome: nil, now: now)
        #expect(p.axToken == PairingConnectionAXState.connecting.axToken)
    }

    @Test func freshSuccessReadsConnected() {
        let outcome = AppState.JournalHeartbeatOutcome(ok: true, at: now.addingTimeInterval(-10))
        let p = makeDirectConnectionPresentation(outcome: outcome, now: now)
        #expect(p.axToken == PairingConnectionAXState.connected.axToken)
        #expect(p.severity == .good)
    }

    @Test func staleSuccessNeverConfidentGreen() {
        let outcome = AppState.JournalHeartbeatOutcome(ok: true, at: now.addingTimeInterval(-120))
        let p = makeDirectConnectionPresentation(outcome: outcome, now: now)
        #expect(p.axToken == PairingConnectionAXState.connecting.axToken)
    }

    @Test func failureReadsDisconnectedHonestly() {
        let outcome = AppState.JournalHeartbeatOutcome(ok: false, at: now)
        let p = makeDirectConnectionPresentation(outcome: outcome, now: now)
        #expect(p.axToken == PairingConnectionAXState.disconnected.axToken)
        #expect(p.severity == .attention)
    }
}

@Suite("LocalJournalConnectionPresentation heartbeat overlay")
struct LocalJournalHeartbeatOverlayTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    @Test func notSyncedWithFreshHeartbeatReadsConnected() {
        let hb = AppState.JournalHeartbeatOutcome(ok: true, at: now.addingTimeInterval(-5))
        let p = makeLocalJournalConnectionPresentation(for: .notSynced, heartbeat: hb, now: now)
        #expect(p.axToken == PairingConnectionAXState.connected.axToken)
    }

    @Test func notSyncedWithStaleHeartbeatStaysConnecting() {
        let hb = AppState.JournalHeartbeatOutcome(ok: true, at: now.addingTimeInterval(-300))
        let p = makeLocalJournalConnectionPresentation(for: .notSynced, heartbeat: hb, now: now)
        #expect(p.axToken == PairingConnectionAXState.connecting.axToken)
    }

    @Test func notSyncedWithFailedHeartbeatStaysConnecting() {
        let hb = AppState.JournalHeartbeatOutcome(ok: false, at: now)
        let p = makeLocalJournalConnectionPresentation(for: .notSynced, heartbeat: hb, now: now)
        #expect(p.axToken == PairingConnectionAXState.connecting.axToken)
    }

    @Test func uploadErrorStatesUnchangedByHeartbeat() {
        let hb = AppState.JournalHeartbeatOutcome(ok: true, at: now)
        let p = makeLocalJournalConnectionPresentation(for: .retrying(segment: "t", attempts: 2), heartbeat: hb, now: now)
        #expect(p.axToken == PairingConnectionAXState.connecting.axToken)
    }
}
