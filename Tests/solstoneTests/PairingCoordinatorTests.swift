// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
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

    @Test func sameInstanceIDRunsCeremonySavesAndSetsAlreadyConnected() async throws {
        let instanceID = "11111111-1111-1111-1111-111111111111"
        let refreshed = pairing(instanceID: instanceID)
        let store = PairingStore(pairing: pairing(instanceID: instanceID.uppercased()))
        let script = PairScript([.success(refreshed)])
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(store: store, script: script, reactivate: reactivate)

        await coordinator.submitPairingLink(relayPairLink(instanceID: instanceID))

        #expect(coordinator.state == .alreadyConnected)
        #expect(store.currentPairing == refreshed)
        #expect(await script.callCount == 1)
        #expect(store.saveCount == 1)
        #expect(await reactivate.count == 1)
    }

    @Test func differentInstanceIDRequiresSwitchConfirmBeforeOverwrite() async throws {
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111")
        let replacement = pairing(instanceID: "22222222-2222-2222-2222-222222222222")
        let store = PairingStore(pairing: prior)
        let script = PairScript([.success(replacement)])
        let coordinator = makeCoordinator(store: store, script: script)

        await coordinator.submitPairingLink(relayPairLink(instanceID: replacement.instanceID))

        #expect(coordinator.state == .switchConfirmPending(newInstanceID: replacement.instanceID))
        #expect(store.currentPairing == prior)
        #expect(store.saveCount == 0)
        #expect(await script.callCount == 1)
    }

    @Test func confirmSwitchRunsCeremonySavesAndSetsSwitched() async throws {
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111")
        let replacement = pairing(instanceID: "22222222-2222-2222-2222-222222222222")
        let store = PairingStore(pairing: prior)
        let script = PairScript([.success(replacement)])
        let reactivate = ReactivateRecorder()
        let clear = ClearRecorder()
        let coordinator = makeCoordinator(store: store, script: script, reactivate: reactivate, clear: clear)

        await coordinator.submitPairingLink(relayPairLink(instanceID: replacement.instanceID))
        await coordinator.confirmSwitch()

        #expect(coordinator.state == .switched)
        #expect(store.currentPairing == replacement)
        #expect(store.savedPairings == [replacement])
        #expect(await script.callCount == 1)
        #expect(await reactivate.count == 1)
        #expect(clear.count == 1)
    }

    @Test func differentInstanceIDCeremonyFailurePreservesPriorPairing() async throws {
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111")
        let replacementID = "22222222-2222-2222-2222-222222222222"
        let store = PairingStore(pairing: prior)
        let script = PairScript([.failure(PairError.nonceExpired)])
        let reactivate = ReactivateRecorder()
        let coordinator = makeCoordinator(store: store, script: script, reactivate: reactivate)

        await coordinator.submitPairingLink(relayPairLink(instanceID: replacementID))

        #expect(coordinator.state == .failed(.staleLink))
        #expect(store.currentPairing == prior)
        #expect(store.saveCount == 0)
        #expect(await script.callCount == 1)
        #expect(await reactivate.count == 0)
    }

    @Test func unpairDeletesPairingReactivatesAndRestoresIdle() async throws {
        let store = PairingStore(pairing: pairing())
        let reactivate = ReactivateRecorder()
        let clear = ClearRecorder()
        let coordinator = makeCoordinator(store: store, outcomes: [], reactivate: reactivate, clear: clear)

        await coordinator.unpair()

        #expect(coordinator.state == .idle)
        #expect(store.currentPairing == nil)
        #expect(store.deleted)
        #expect(store.deleteCount == 1)
        #expect(await reactivate.count == 1)
        #expect(clear.count == 1)
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

    @Test func directDifferentInstanceIDRequiresSwitchConfirmBeforeOverwrite() async throws {
        let prior = pairing(instanceID: "11111111-1111-1111-1111-111111111111")
        let replacement = pairing(instanceID: "22222222-2222-2222-2222-222222222222")
        let store = PairingStore(pairing: prior)
        let script = PairScript([.success(replacement)])
        let reactivate = ReactivateRecorder()
        let clear = ClearRecorder()
        let coordinator = makeCoordinator(store: store, script: script, reactivate: reactivate, clear: clear)

        await coordinator.submitPairingLink(directPairLink)

        #expect(coordinator.state == .switchConfirmPending(newInstanceID: replacement.instanceID))
        #expect(store.currentPairing == prior)
        #expect(store.saveCount == 0)
        #expect(await reactivate.count == 0)
        #expect(clear.count == 0)
        #expect(await script.callCount == 1)

        await coordinator.confirmSwitch()

        #expect(coordinator.state == .switched)
        #expect(store.currentPairing == replacement)
        #expect(store.savedPairings == [replacement])
        #expect(store.saveCount == 1)
        #expect(await reactivate.count == 1)
        #expect(clear.count == 1)
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
        clear: ClearRecorder = ClearRecorder()
    ) -> PairingCoordinator {
        makeCoordinator(
            store: store,
            script: PairScript(outcomes),
            reactivate: reactivate,
            clear: clear
        )
    }

    private func makeCoordinator(
        store: PairingStore,
        script: PairScript,
        reactivate: ReactivateRecorder = ReactivateRecorder(),
        ownerState: TunnelLifecycleState = .disconnected,
        clear: ClearRecorder = ClearRecorder()
    ) -> PairingCoordinator {
        PairingCoordinator(
            pair: { pairURL, deviceLabel, relayEndpoint in
                try await script.pair(pairURL: pairURL, deviceLabel: deviceLabel, relayEndpoint: relayEndpoint)
            },
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() },
            reactivate: {
                await reactivate.record()
            },
            ownerState: { ownerState },
            relayEndpoint: { URL(string: "https://relay.test")! },
            deviceLabel: { "test mac" },
            clearLastSuccessfulJournalContact: { clear.record() }
        )
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

    var callCount: Int {
        calls.count
    }

    init(_ outcomes: [PairScriptOutcome]) {
        self.outcomes = outcomes
    }

    func pair(pairURL: PairURL, deviceLabel: String, relayEndpoint: URL) throws -> StoredPairing {
        calls.append(PairCall(pairURL: pairURL, deviceLabel: deviceLabel, relayEndpoint: relayEndpoint))
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

// 0x04 direct: 192.168.1.42:7070.
private let directPairLink = "https://go.solstone.app/p#0G0W1A0158DSW48H248H248H248H248H248H249248H248H248H248H248H248H2"

// 0x05 direct: 10.0.0.7:7070, then 100.64.3.9:7070.
private let directMultiCandidatePairLink = "https://go.solstone.app/p#0M0G46WY180001V4801GJ48H248H248H248H248H248H249248H248H248H248H248H248H2"

private func relayPairLink(instanceID _: String) -> String {
    "https://go.solstone.app/p#0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00"
}
