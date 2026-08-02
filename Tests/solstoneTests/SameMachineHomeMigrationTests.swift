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

    @Test func sameMachineHomeIsNeverAskedToConfirmAMark() {
        // Adopting an existing loopback install runs the pairing ceremony, and the ceremony ends
        // by asking the owner to compare journal marks. On a journal reached over a verified
        // loopback-only link there is no second home it could be, so the question has one
        // possible answer — and asking it on upgrade parks the settings pane behind a modal the
        // owner never asked for.
        let driver = JournalMarkConfirmationDriver()
        let homeState = AppState.forSnapshot(initialTunnelPairing: pairing(
            localEndpoints: [
                LocalEndpoint(host: "127.0.0.1", port: 5015, scope: "local")
            ]
        ))
        #expect(homeState.isPairedHome)

        driver.startIfNeeded(for: .paired, appState: homeState)

        #expect(!driver.isPresented)
    }

    @Test func aJournalOnAnotherMachineStillConfirmsItsMark() {
        // The guard above must not disarm the mark everywhere: a home reached over the network is
        // exactly the case the comparison exists for.
        let driver = JournalMarkConfirmationDriver()
        let remoteState = AppState.forSnapshot(initialTunnelPairing: pairing(
            localEndpoints: [
                LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan")
            ]
        ))
        #expect(!remoteState.isPairedHome)

        driver.startIfNeeded(for: .paired, appState: remoteState)

        #expect(driver.isPresented)
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

    @Test func sameMachineCeremonyRefreshesPairedHomeBeforeResultText() async throws {
        let remotePairing = pairing(
            instanceID: "remote-home",
            localEndpoints: [
                LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan")
            ]
        )
        let homePairing = pairing(instanceID: "home-instance")
        let store = PairingStore(pairing: remotePairing)
        let initialTransport = FakeTunnelTransport()
        initialTransport.armConnectGate()
        let replacementTransport = FakeTunnelTransport()
        let transportFactory = FakeTransportFactory([initialTransport, replacementTransport])
        let owner = TunnelLifecycleOwner(
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() },
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(remotePairing)]).seam,
            makeTransport: { transportFactory.make() },
            pathMonitoringSource: NoopPathMonitoringSource()
        )
        let coordinator = PairingCoordinator(
            pair: { _, _, _ in homePairing },
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() },
            reactivate: { await owner.reevaluatePairing() },
            ownerState: { owner.state },
            relayEndpoint: { URL(string: "https://relay.test")! },
            deviceLabel: { "test mac" }
        )

        owner.start()
        try await waitUntil {
            initialTransport.pendingConnectCount == 1
        }
        try store.delete()

        await coordinator.submitPairingLink(loopbackDirectPairLink)

        #expect(coordinator.state == .paired)
        #expect(owner.isPairedHome)
        #expect(pairingResultText(
            for: coordinator.state,
            isPairedHome: owner.isPairedHome,
            sameMachineHomeMigrationComplete: false
        ) == nil)

        initialTransport.releaseNextConnect()
        await owner.stop()
    }

    @Test func pairedHomeIncompleteMigrationUsesTunnelConnectionPresentation() {
        let tunnelPresentation = PairingConnectionPresentation(
            message: "connecting to your journal…",
            severity: .warn,
            axToken: PairingConnectionAXState.connecting.axToken
        )
        let presentation = journalConnectionPresentation(
            serverURL: ServiceMode.bundledServiceURL,
            isUploadConfigured: true,
            isPairedHome: true,
            sameMachineHomeMigrationComplete: false,
            uploadStatus: .notSynced,
            heartbeat: AppState.JournalHeartbeatOutcome(ok: true, at: Date(timeIntervalSince1970: 0)),
            pairingPresentation: tunnelPresentation
        )

        #expect(presentation.message == tunnelPresentation.message)
        #expect(presentation.severity == tunnelPresentation.severity)
        #expect(presentation.axToken == tunnelPresentation.axToken)
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
