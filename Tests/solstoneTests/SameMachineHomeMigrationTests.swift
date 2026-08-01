// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntimeTestSupport
import ServiceManagement
import SolstoneCore
import SPLTunnel
import Testing
@testable import solstone

@Suite("Same-machine home migration", .serialized)
@MainActor
struct SameMachineHomeMigrationTests {
    @Test func remoteJournalDoesNotStartSameMachineFlow() async {
        let pairStart = PairStartRecorder(responses: [
            .failure(SameMachinePairStartFailure(kind: .transport, detail: "should not start"))
        ])
        let state = AppState.forLoginItemTest(
            config: AppConfig(
                serverURL: "https://journal.example",
                serverKey: "legacy-key",
                serviceMode: .external
            ),
            loginService: NoopLoginItemService(),
            sameMachinePairStart: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            }
        )

        state.noteJournalHeartbeatOutcome(true)

        #expect(await pairStart.callCount == 0)
        #expect(state.sameMachineMigrationLastResult == nil)
    }

    @Test func heartbeatTriggerFiresAtMostOncePerLaunchAndDoesNotFireOnFalse() async throws {
        let pairStart = PairStartRecorder(responses: [
            .failure(SameMachinePairStartFailure(kind: .httpStatus(503), detail: "not ready")),
            .failure(SameMachinePairStartFailure(kind: .httpStatus(503), detail: "should not retry"))
        ])
        let state = AppState.forLoginItemTest(
            config: loopbackRegisteredConfig(),
            loginService: NoopLoginItemService(),
            sameMachinePairStart: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            }
        )

        state.noteJournalHeartbeatOutcome(false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await pairStart.callCount == 0)

        state.noteJournalHeartbeatOutcome(true)
        try await waitUntil {
            await pairStart.callCount == 1
        }
        #expect(state.sameMachineMigrationLastResult == SameMachineHomePairingResult.failed(.pairStart(.httpStatus(503))))

        state.noteJournalHeartbeatOutcome(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await pairStart.callCount == 1)
    }

    @Test func existingDifferentPairingBlocksBeforePairStart() async {
        let pairStart = PairStartRecorder(responses: [
            .success(sameMachinePairStartResponse(pairLink: loopbackDirectPairLink))
        ])
        let submit = PairLinkSubmitRecorder(result: .switchConfirmPending(newInstanceID: "new-home"))

        let result = await performSameMachineHomePairing(
            baseURL: ServiceMode.bundledServiceURL,
            existingPairing: .differentHomeHeld,
            startPairing: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            },
            submitPairingLink: { link in
                await submit.submit(link)
            }
        )

        #expect(result == .failed(.differentHomeAlreadyPaired))
        #expect(await pairStart.callCount == 0)
        #expect(await submit.links.isEmpty)
    }

    @Test func exposesDerivedPairedHomeState() {
        let homeState = AppState.forSnapshot(initialTunnelPairing: pairing(
            localEndpoints: [
                LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan"),
                LocalEndpoint(host: "127.0.0.1", port: 5015, scope: "local")
            ]
        ))
        let remoteState = AppState.forSnapshot(initialTunnelPairing: pairing(
            localEndpoints: [
                LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan")
            ]
        ))

        #expect(homeState.isPairedHome)
        #expect(!remoteState.isPairedHome)
    }

    @Test func pairStartRefusedReportsNotYetPairedAndCaptureContinues() async {
        let state = AppState.forSnapshot(config: loopbackRegisteredConfig())
        state.isRecording = true
        let pairStart = PairStartRecorder(responses: [
            .failure(SameMachinePairStartFailure(kind: .httpStatus(400), detail: "refused"))
        ])

        let result = await performSameMachineHomePairing(
            baseURL: ServiceMode.bundledServiceURL,
            existingPairing: .noneHeld,
            startPairing: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            },
            submitPairingLink: { _ in
                Issue.record("pair client should not be invoked after pair-start refusal")
                return .paired
            }
        )

        #expect(result == .failed(.pairStart(.httpStatus(400))))
        #expect(!state.sameMachineHomeMigrationComplete)
        #expect(state.isRecording)
    }

    @Test func wrongLinkShapeReportsNotYetPairedAndCaptureContinues() async {
        let state = AppState.forSnapshot(config: loopbackRegisteredConfig())
        state.isRecording = true
        let pairStart = PairStartRecorder(responses: [
            .success(sameMachinePairStartResponse(pairLink: lanDirectPairLink))
        ])

        let result = await performSameMachineHomePairing(
            baseURL: ServiceMode.bundledServiceURL,
            existingPairing: .noneHeld,
            startPairing: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            },
            submitPairingLink: { _ in
                Issue.record("pair client should not be invoked for wrong link shape")
                return .paired
            }
        )

        #expect(result == .failed(.linkShape(.lanCandidate)))
        #expect(!state.sameMachineHomeMigrationComplete)
        #expect(state.isRecording)
    }

    @Test func ceremonyRejectedReportsNotYetPairedAndCaptureContinues() async {
        let state = AppState.forSnapshot(config: loopbackRegisteredConfig())
        state.isRecording = true
        let pairStart = PairStartRecorder(responses: [
            .success(sameMachinePairStartResponse(pairLink: loopbackDirectPairLink))
        ])

        let result = await performSameMachineHomePairing(
            baseURL: ServiceMode.bundledServiceURL,
            existingPairing: .noneHeld,
            startPairing: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            },
            submitPairingLink: { _ in .failed(.homeUnreachable) }
        )

        #expect(result == .failed(.ceremony(.failed(.homeUnreachable))))
        #expect(!state.sameMachineHomeMigrationComplete)
        #expect(state.isRecording)
    }

    @Test func registrationRefusedReportsNotYetPairedAndCaptureContinues() async {
        let state = AppState.forSnapshot(
            config: loopbackRegisteredConfig(),
            initialTunnelPairing: pairing()
        )
        state.isRecording = true
        let registrar = FakeObserverRegistrar(result: .failure(ObserverRegistrationFailure(
            kind: .httpStatus(500),
            detail: "refused"
        )))

        await performTunnelObserverRegistration(
            appState: state,
            isTunnelManaged: true,
            resolveBase: { .url("http://127.0.0.1:49152") },
            register: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            }
        )

        #expect(registrar.invocationCount == 1)
        #expect(state.config.serverURL == ServiceMode.bundledServiceURL)
        #expect(!state.sameMachineHomeMigrationComplete)
        #expect(state.isRecording)
    }

    @Test func tunnelBaseUnresolvedAfterSuccessfulCeremonyReportsNotYetPairedAndCaptureContinues() async {
        let state = AppState.forSnapshot(
            config: loopbackRegisteredConfig(),
            initialTunnelPairing: pairing()
        )
        state.isRecording = true
        let registrar = FakeObserverRegistrar()

        await performTunnelObserverRegistration(
            appState: state,
            isTunnelManaged: true,
            resolveBase: { .held },
            register: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            }
        )

        #expect(registrar.invocationCount == 0)
        #expect(state.config.serverURL == ServiceMode.bundledServiceURL)
        #expect(!state.sameMachineHomeMigrationComplete)
        #expect(state.isRecording)
    }

    @Test func loopbackRegisteredConfigMigratesAndAdoptsExistingObserver() async throws {
        let adoptedPairing = pairing(instanceID: "home-instance")
        let store = PairingStore(pairing: nil)
        let pairStart = PairStartRecorder(responses: [
            .success(sameMachinePairStartResponse(pairLink: loopbackDirectPairLink))
        ])
        let linkBaseURL = "http://127.0.0.1:49152"
        let registrar = FakeObserverRegistrar(result: .success(ObserverRegistration(
            key: "legacy-key",
            streamName: "linked-stream"
        )))
        let state = AppState.forLoginItemTest(
            config: loopbackRegisteredConfig(),
            loginService: NoopLoginItemService(),
            sameMachinePairStart: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            },
            pairingOperation: { _, _, _ in adoptedPairing },
            pairingLoad: { try store.load() },
            pairingSave: { try store.save($0) },
            pairingDelete: { try store.delete() }
        )

        state.noteJournalHeartbeatOutcome(true)
        try await waitUntil {
            state.sameMachineMigrationLastResult == SameMachineHomePairingResult.pairingStarted
        }
        #expect(store.savedPairings == [adoptedPairing])
        #expect(state.isPairedHome)

        await performTunnelObserverRegistration(
            appState: state,
            isTunnelManaged: true,
            resolveBase: { .url(linkBaseURL) },
            register: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            }
        )

        #expect(await pairStart.callCount == 1)
        #expect(registrar.invocationCount == 1)
        #expect(state.config.serverURL == linkBaseURL)
        #expect(state.config.serverKey == "legacy-key")
        #expect(state.config.observerName == "linked-stream")
        #expect(state.config.serviceMode == .external)
        #expect(state.sameMachineHomeMigrationComplete)
    }

    @Test func journalLocationLabelReflectsPairedHomeAndBundledBase() {
        #expect(journalLocationLabel(
            isPairedHome: true,
            serverURL: "http://127.0.0.1:49152"
        ) == UICopy.JOURNAL_MODE_THIS_MAC_LABEL)
        #expect(journalLocationLabel(
            isPairedHome: false,
            serverURL: ServiceMode.bundledServiceURL
        ) == UICopy.JOURNAL_MODE_THIS_MAC_LABEL)
        #expect(journalLocationLabel(
            isPairedHome: false,
            serverURL: "https://journal.example"
        ) == UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL)
    }

    @Test func pairedHomePairingResultTextWaitsForBaseMove() {
        #expect(pairingResultText(
            for: .paired,
            isPairedHome: true,
            sameMachineHomeMigrationComplete: false
        ) == nil)
        #expect(pairingResultText(
            for: .paired,
            isPairedHome: true,
            sameMachineHomeMigrationComplete: true
        ) == "paired ✓")
    }
}

private func loopbackRegisteredConfig() -> AppConfig {
    AppConfig(
        serverURL: ServiceMode.bundledServiceURL,
        serverKey: "legacy-key",
        serviceMode: .external
    )
}

private func sameMachinePairStartResponse(pairLink: String) -> SameMachinePairStartResponse {
    SameMachinePairStartResponse(
        nonce: "nonce-1",
        pairLink: pairLink,
        expiresIn: 300,
        deviceLabel: "test mac",
        caFingerprint: "ca-fingerprint"
    )
}

@MainActor
private final class NoopLoginItemService: LoginItemService {
    var watchdogStatus: SMAppService.Status = .notRegistered
    var mainAppStatus: SMAppService.Status = .notRegistered

    func registerWatchdog() throws {}
    func unregisterWatchdog() throws {}
    func unregisterMainApp() throws {}
}
