// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
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

        state.triggerSameMachineMigrationIfEligible()

        #expect(await pairStart.callCount == 0)
        #expect(state.sameMachineMigrationLastResult == nil)
    }

    @Test func launchTriggerFiresAtMostOncePerLaunch() async throws {
        let pairStart = PairStartRecorder(responses: [
            .failure(SameMachinePairStartFailure(kind: .httpStatus(400), detail: "refused")),
        ])
        let state = AppState.forLoginItemTest(
            config: loopbackRegisteredConfig(),
            loginService: NoopLoginItemService(),
            sameMachinePairStart: { baseURL, deviceLabel in
                await pairStart.start(baseURL: baseURL, deviceLabel: deviceLabel)
            }
        )

        state.triggerSameMachineMigrationIfEligible()
        try await waitUntil {
            await pairStart.callCount == 1
        }
        #expect(state.sameMachineMigrationLastResult == SameMachineHomePairingResult.failed(.pairStart(.httpStatus(400))))

        state.triggerSameMachineMigrationIfEligible()
        state.triggerSameMachineMigrationIfEligible()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await pairStart.callCount == 1)
    }

    @Test func transientPairStartFailureRetriesAndCanSucceed() async throws {
        let adoptedPairing = pairing(instanceID: "home-instance")
        let store = PairingStore(pairing: nil)
        let pairStart = PairStartRecorder(responses: [
            .failure(SameMachinePairStartFailure(kind: .transport, detail: "journal starting")),
            .success(sameMachinePairStartResponse(pairLink: loopbackDirectPairLink)),
        ])
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

        state.triggerSameMachineMigrationIfEligible()

        try await waitUntil(timeout: .seconds(3)) { @MainActor in
            state.sameMachineMigrationLastResult == .pairingStarted
        }
        #expect(await pairStart.callCount == 2)
        #expect(state.sameMachineHomeMigrationComplete)
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

    @Test func automaticAdoptionDoesNotAskTheOwnerToConfirmAMark() {
        // The adoption runs during launch after an upgrade. It re-uses the pairing ceremony to
        // take over a journal the owner already had linked here, so the mark question would land
        // unrequested and hold settings behind a modal.
        let driver = JournalMarkConfirmationDriver()
        let state = AppState.forSnapshot(initialTunnelPairing: pairing(
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 5015, scope: "local")]
        ))
        state.isAdoptingSameMachineHomeAutomatically = true

        driver.startIfNeeded(for: .paired, appState: state)

        #expect(!driver.isPresented)
    }

    @Test func ownerInitiatedSameMachinePairingStillConfirmsItsMark() {
        // Regression guard. Keying the exemption on "is a same-machine home" instead of "is the
        // automatic adoption" also silences the mark on a *fresh* local link, which is an
        // owner-initiated pairing that must confirm — the release gate drives that confirmation
        // and fails `pairing_mark_absent` without it.
        let driver = JournalMarkConfirmationDriver()
        let state = AppState.forSnapshot(initialTunnelPairing: pairing(
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 5015, scope: "local")]
        ))
        #expect(state.isPairedHome)
        #expect(!state.isAdoptingSameMachineHomeAutomatically)

        driver.startIfNeeded(for: .paired, appState: state)

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

    @Test func loopbackRegisteredConfigMigratesAndAdoptsExistingPairedHome() async throws {
        let adoptedPairing = pairing(instanceID: "home-instance")
        let store = PairingStore(pairing: nil)
        let pairStart = PairStartRecorder(responses: [
            .success(sameMachinePairStartResponse(pairLink: loopbackDirectPairLink))
        ])
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

        state.triggerSameMachineMigrationIfEligible()
        try await waitUntil {
            state.sameMachineMigrationLastResult == SameMachineHomePairingResult.pairingStarted
        }
        #expect(store.savedPairings == [adoptedPairing])
        #expect(state.isPairedHome)

        // The mark suppression must outlive the migration call. The ceremony's final state is
        // observed asynchronously, so the mark driver runs after this point — clearing the flag
        // when the migration returns closes the window before the thing it protects happens.
        // That exact mistake passed its unit tests and still put the mark sheet on the rig.
        #expect(state.isAdoptingSameMachineHomeAutomatically)

        #expect(await pairStart.callCount == 1)
        #expect(state.config.serverURL == ServiceMode.bundledServiceURL)
        #expect(state.config.serverKey == "legacy-key")
        #expect(state.config.observerName == nil)
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

    @Test func pairedHomePairingResultTextRequiresCompletedMigration() {
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

    @Test func sameMachineCeremonyShowsResultOncePairedHomeIsStored() async throws {
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
            sameMachineHomeMigrationComplete: owner.isPairedHome
        ) == "paired ✓")

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
    func unregisterWatchdogAwaitingCompletion() async throws {}
    func unregisterMainApp() throws {}
}
