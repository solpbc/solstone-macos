// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SPLTunnel
import SolstoneCore
@testable import solstone

@MainActor
private final class CallCounter: @unchecked Sendable {
    var count = 0
}

@Suite("SolstoneURLIngressTests")
@MainActor
struct SolstoneURLIngressTests {
    private let sampleFragment = "0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00"
    private var canonicalSample: String {
        "https://go.solstone.app/p#\(sampleFragment)"
    }

    private func makeSetupState() throws -> AppState {
        let dir = URL(fileURLWithPath: "/var/tmp").appendingPathComponent("setup-ingress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppState.forSnapshot(setupModel: SetupModel(enabled: true, mailboxDirectory: dir))
    }

    @Test func unqualifiedAppPrefillsOrdinaryPairFieldWithoutPairing() {
        let state = AppState.forSnapshot()
        #expect(state.setupModel.phase == nil)
        state.handleIngressURLString("solstone://pair#\(sampleFragment)")
        #expect(state.takePendingPairingLink(forSetup: true) == nil)
        #expect(state.takePendingPairingLink(forSetup: false) == canonicalSample)
        #expect(state.pairingCoordinator.state == .idle)
        #expect(state.currentDurablePairing == nil)
    }

    @Test func onlyVisibleSurfaceConsumesColdAndWarmLinksWithoutPairing() throws {
        let state = try makeSetupState()
        let dir = state.setupModel.continuationStore.directory
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(state.setupModel.setPhase(.microphone))
        for _ in 0..<2 {
            state.handleIngressURLString("solstone://pair#\(sampleFragment)")
            #expect(state.takePendingPairingLink(forSetup: false) == nil)
            #expect(state.pendingPairingLink == canonicalSample)
            #expect(state.takePendingPairingLink(forSetup: true) == canonicalSample)
            #expect(state.pendingPairingLink == nil)
            #expect(state.pairingCoordinator.state == .idle)
            #expect(state.currentDurablePairing == nil)
        }
        #expect(state.setupModel.setPhase(nil))
        state.handleIngressURLString("solstone://pair#\(sampleFragment)")
        #expect(state.takePendingPairingLink(forSetup: true) == nil)
        #expect(state.takePendingPairingLink(forSetup: false) == canonicalSample)
        #expect(state.pairingCoordinator.state == .idle)
    }

    @Test func ownerModeSaveFailurePreventsSubmissionAndKeepsSupportingContinuation() async throws {
        let state = try makeSetupState()
        let model = state.setupModel
        let store = model.continuationStore
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(model.setPhase(.journal))
        model.stopJournalPolling()
        let handoff = SetupHandoff(handoffID: UUID(), stepIndex: 5,
            journalRootPath: "/fixture/journal", expectedInstanceID: "fixture-instance",
            expectedCAFingerprint: String(repeating: "a", count: 64))
        try model.mailboxStore.writeStep5(handoff)
        model.ingestStep5IfNeeded()
        let accepted = model.continuation
        #expect(model.isPeerSupportingSetup)
        // Make only this disposable continuation file unwritable by occupying its pathname.
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        state.setConfirmedMark(.uiTestSample)
        let result = await state.submitPairingInput(canonicalSample)
        #expect(result == .idle)
        #expect(model.ownerPairingError != nil)
        #expect(model.continuation == accepted)
        #expect(model.isPeerSupportingSetup)
        #expect(state.confirmedMark == .uiTestSample)
        #expect(state.currentDurablePairing == nil)
    }

    @Test func translatesBothSlashForms() {
        let withoutSlash = "solstone://pair#\(sampleFragment)"
        let withSlash = "solstone://pair/#\(sampleFragment)"

        #expect(translatePairingLink(withoutSlash) == .success(canonicalSample))
        #expect(translatePairingLink(withSlash) == .success(canonicalSample))
    }

    @Test func translatesCaseInsensitiveSchemeAndHost() {
        let mixed = "SOLSTONE://PAIR#\(sampleFragment)"
        #expect(translatePairingLink(mixed) == .success(canonicalSample))
    }

    @Test func httpsPasteStillParses() {
        let httpsLink = canonicalSample
        #expect(translatePairingLink(httpsLink) == .success(canonicalSample))
    }

    @Test func queryReturnsWrongPath() {
        let withQuery = "solstone://pair?code=123#\(sampleFragment)"
        let res = translatePairingLink(withQuery)
        guard case .failure(let error) = res else {
            Issue.record("expected failure, got \(res)")
            return
        }
        guard case .wrongPath = error else {
            Issue.record("expected .wrongPath, got \(error)")
            return
        }
    }

    @Test func extraPathReturnsWrongPath() {
        let withExtraPath = "solstone://pair/extra#\(sampleFragment)"
        let res = translatePairingLink(withExtraPath)
        guard case .failure(let error) = res else {
            Issue.record("expected failure, got \(res)")
            return
        }
        guard case .wrongPath(let path) = error else {
            Issue.record("expected .wrongPath, got \(error)")
            return
        }
        #expect(path == "/extra")
    }

    @Test func bareOrEmptyFragmentReturnsMissingFragment() {
        let bare = "solstone://pair#"
        let empty = "solstone://pair"

        #expect(translatePairingLink(bare) == .failure(.missingFragment))
        #expect(translatePairingLink(empty) == .failure(.missingFragment))
    }

    @Test func trimsWhitespace() {
        let padded = "  solstone://pair#\(sampleFragment)  \n"
        #expect(translatePairingLink(padded) == .success(canonicalSample))
    }

    @Test func decideIngressPairingStoresWhenIdleAndNoneHeld() {
        let decision = decideIngressPairing(
            flowState: .idle,
            heldState: .noneHeld,
            canonicalLink: canonicalSample
        )
        #expect(decision == .store(canonicalSample))
    }

    @Test func decideIngressPairingLeavesUntouchedWhenPairing() {
        let decision = decideIngressPairing(
            flowState: .pairing,
            heldState: .noneHeld,
            canonicalLink: canonicalSample
        )
        #expect(decision == .leaveUntouched)
    }

    @Test func decideIngressPairingLeavesUntouchedWhenHomeHeld() {
        let decision = decideIngressPairing(
            flowState: .idle,
            heldState: .pairedHome,
            canonicalLink: canonicalSample
        )
        #expect(decision == .leaveUntouched)
    }

    @Test func appStateIngressSetsPendingPairingLinkWhileCoordinatorRemainsIdle() {
        let state = AppState.forSnapshot()
        #expect(state.pendingPairingLink == nil)
        #expect(state.pairingCoordinator.state == PairingFlowState.idle)

        state.handleIngressURLString("solstone://pair#\(sampleFragment)")

        #expect(state.pendingPairingLink == canonicalSample)
        #expect(state.pairingCoordinator.state == PairingFlowState.idle)
    }

    @Test func appStateIngressIgnoresInvalidURLLeavingPendingPairingLinkNil() {
        let state = AppState.forSnapshot()
        state.handleIngressURLString("solstone://wrong#\(sampleFragment)")
        #expect(state.pendingPairingLink == nil)
        #expect(state.pendingPairingLinkError == PairingCoordinator.invalidLinkReason(.wrongHost("wrong")))
        #expect(state.pairingCoordinator.state == PairingFlowState.idle)
    }

    @Test func handleIngressURLStringInSetupPhaseBringsSolstoneToFrontOnce() throws {
        let state = try makeSetupState()
        let dir = state.setupModel.continuationStore.directory
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(state.setupModel.setPhase(.microphone))
        let counter = CallCounter()
        state.bringSolstoneToFront = { counter.count += 1 }

        state.handleIngressURLString("solstone://pair#\(sampleFragment)")
        #expect(counter.count == 1)
        #expect(state.pendingPairingLink == canonicalSample)
        #expect(state.pendingSettingsTab == "journal")
    }

    @Test func handleIngressURLStringWhenPhaseNilBringsSolstoneToFrontPerCall() {
        let state = AppState.forSnapshot()
        #expect(state.setupModel.phase == nil)
        let counter = CallCounter()
        state.bringSolstoneToFront = { counter.count += 1 }

        state.handleIngressURLString("solstone://pair#\(sampleFragment)")
        #expect(counter.count == 1)
        #expect(state.pendingPairingLink == canonicalSample)
        #expect(state.pendingSettingsTab == "journal")

        state.handleIngressURLString("solstone://pair#\(sampleFragment)")
        #expect(counter.count == 2)
        #expect(state.pendingPairingLink == canonicalSample)
        #expect(state.pendingSettingsTab == "journal")
    }

    @Test func handleIngressURLStringInvalidURLDoesNotBringSolstoneToFront() {
        let state = AppState.forSnapshot()
        let counter = CallCounter()
        state.bringSolstoneToFront = { counter.count += 1 }

        state.handleIngressURLString("solstone://wrong#\(sampleFragment)")
        #expect(counter.count == 0)
        #expect(state.pendingPairingLink == nil)
        #expect(state.pendingPairingLinkError == PairingCoordinator.invalidLinkReason(.wrongHost("wrong")))
    }

    @Test func handleIngressURLStringWithHeldStateDoesNotBringSolstoneToFront() {
        let state = AppState.forSnapshot(initialTunnelPairing: pairing())
        let counter = CallCounter()
        state.bringSolstoneToFront = { counter.count += 1 }

        state.handleIngressURLString("solstone://pair#\(sampleFragment)")
        #expect(counter.count == 0)
        #expect(state.pendingPairingLink == nil)
    }
}
