// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("Same-machine home pairing flow")
@MainActor
struct SameMachineHomePairingFlowTests {
    @Test func directLoopbackLinkExactStringReachesPairClient() async throws {
        let pairStart = PairStartRecorder(responses: [
            .success(response(pairLink: loopbackDirectPairLink))
        ])
        let submit = PairLinkSubmitRecorder(result: .paired)

        let result = await performSameMachineHomePairing(
            baseURL: "http://127.0.0.1:5015",
            existingPairing: .noneHeld,
            startPairing: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            },
            submitPairingLink: { link in
                await submit.submit(link)
            }
        )

        #expect(result == .pairingStarted)
        #expect(await submit.links == [loopbackDirectPairLink])
    }

    @Test func rejectsLanCandidateWithoutPairClient() async {
        await expectRejected(
            pairLink: lanDirectPairLink,
            rejection: .lanCandidate
        )
    }

    @Test func rejectsRelayPairWindowWithoutPairClient() async {
        await expectRejected(
            pairLink: relayPairWindowLink,
            rejection: .relayPairWindow
        )
    }

    @Test func rejectsNoCandidatesWithoutPairClient() async {
        await expectRejected(
            pairLink: loopbackDirectPairLink,
            rejection: .noCandidates,
            verifier: { _ in .failure(.noCandidates) }
        )
    }

    @Test func rejectsMultipleCandidatesWithoutPairClient() async {
        await expectRejected(
            pairLink: multiLoopbackDirectPairLink,
            rejection: .multipleCandidates
        )
    }

    @Test func rejectsUnparsableLinkWithoutPairClient() async {
        await expectRejected(
            pairLink: "not a pairing link",
            rejection: .unparsable
        )
    }

    @Test func ceremonyRejectedReportsFailureWithoutSuccess() async {
        let pairStart = PairStartRecorder(responses: [
            .success(response(pairLink: loopbackDirectPairLink))
        ])
        let submit = PairLinkSubmitRecorder(result: .failed(.homeUnreachable))

        let result = await performSameMachineHomePairing(
            baseURL: "http://127.0.0.1:5015",
            existingPairing: .noneHeld,
            startPairing: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            },
            submitPairingLink: { link in
                await submit.submit(link)
            }
        )

        #expect(result == .failed(.ceremony(.failed(.homeUnreachable))))
        #expect(await submit.links == [loopbackDirectPairLink])
    }

    private func expectRejected(
        pairLink: String,
        rejection: SameMachinePairLinkRejection,
        verifier: @escaping @Sendable (String) -> Result<Void, SameMachinePairLinkRejection> = {
            verifySameMachinePairLink($0)
        }
    ) async {
        let pairStart = PairStartRecorder(responses: [
            .success(response(pairLink: pairLink))
        ])
        let submit = PairLinkSubmitRecorder(result: .paired)

        let result = await performSameMachineHomePairing(
            baseURL: "http://127.0.0.1:5015",
            existingPairing: .noneHeld,
            startPairing: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            },
            verifyPairLink: verifier,
            submitPairingLink: { link in
                await submit.submit(link)
            }
        )

        #expect(result == .failed(.linkShape(rejection)))
        #expect(await submit.links.isEmpty)
    }

    private func response(pairLink: String) -> SameMachinePairStartResponse {
        SameMachinePairStartResponse(
            nonce: "nonce-1",
            pairLink: pairLink,
            expiresIn: 300,
            deviceLabel: "test mac",
            caFingerprint: "ca-fingerprint"
        )
    }
}

actor PairStartRecorder {
    private var responses: [Result<SameMachinePairStartResponse, SameMachinePairStartFailure>]
    private(set) var calls: [(baseURL: String, deviceLabel: String)] = []

    init(responses: [Result<SameMachinePairStartResponse, SameMachinePairStartFailure>]) {
        self.responses = responses
    }

    var callCount: Int {
        calls.count
    }

    func start(
        baseURL: String,
        deviceLabel: String
    ) -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure> {
        calls.append((baseURL: baseURL, deviceLabel: deviceLabel))
        guard !responses.isEmpty else {
            return .failure(SameMachinePairStartFailure(kind: .transport, detail: "no response"))
        }
        return responses.removeFirst()
    }
}

actor PairLinkSubmitRecorder {
    private let result: PairingFlowState
    private(set) var links: [String] = []

    init(result: PairingFlowState) {
        self.result = result
    }

    func submit(_ link: String) -> PairingFlowState {
        links.append(link)
        return result
    }
}
