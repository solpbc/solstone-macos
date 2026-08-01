// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntimeTestSupport
import Testing
import SolstoneCore
@testable import solstone

@Suite("Journal client behavior", .serialized)
@MainActor
struct JournalClientBehaviorTests {
    @Test func localDiscoveryReturnsForkWhenIdentityUncommittedOrAbsent() async {
        let uncommitted = await discoverLocalJournal { _ in nil }
        let absent = await discoverLocalJournal { _ in nil }

        #expect(uncommitted == .fork)
        #expect(absent == .fork)
    }

    @Test func localDiscoveryProbeRunsOnlyForUnconfiguredNonTunnelState() {
        #expect(shouldProbeLocalJournal(
            isUploadConfigured: false,
            isTunnelManaged: false,
            localDiscoveryCompleted: false
        ))
        #expect(!shouldProbeLocalJournal(
            isUploadConfigured: false,
            isTunnelManaged: true,
            localDiscoveryCompleted: false
        ))
        #expect(!shouldProbeLocalJournal(
            isUploadConfigured: true,
            isTunnelManaged: false,
            localDiscoveryCompleted: false
        ))
        #expect(!shouldProbeLocalJournal(
            isUploadConfigured: false,
            isTunnelManaged: false,
            localDiscoveryCompleted: true
        ))
    }

    @Test func sameKeyRelinkStillPresentsMarkOverlayAfterReset() async throws {
        let state = AppState.forSnapshot()
        state.setConfirmedMark(.uiTestSample)
        let driver = makeDriver()
        let successKey = "local-link:observer-key"

        driver.startIfNeeded(
            for: successKey,
            resolveHomeBase: { .url(ServiceMode.bundledServiceURL) },
            fetchMark: { _ in .uiTestSample }
        )
        try await waitForValid(driver)
        driver.cancel()

        driver.startIfNeeded(
            for: successKey,
            resolveHomeBase: { .url(ServiceMode.bundledServiceURL) },
            fetchMark: { _ in .uiTestSample }
        )
        #expect(!driver.isPresented)

        resetForJournalRelink(appState: state, journalMarkDriver: driver)
        #expect(state.confirmedMark == nil)

        driver.startIfNeeded(
            for: successKey,
            resolveHomeBase: { .url(ServiceMode.bundledServiceURL) },
            fetchMark: { _ in .uiTestSample }
        )
        try await waitForValid(driver)
        #expect(driver.isPresented)
        driver.cancel()
    }

    @Test func journalNameFallbackChainUsesFetchedNameThenMarkThenHost() async {
        let (fetcher, namedStore, namedSession) = makeJournalNameFetcher()
        defer { namedSession.invalidateAndCancel() }
        namedStore.enqueue(body: #"{"journal":{"name":"  named journal  "}}"#)
        let fetched = await fetcher.fetch(baseURL: "https://journal.example")

        #expect(resolvedJournalDisplayName(
            fetchedName: fetched,
            confirmedMark: .uiTestSample,
            serverURL: "https://journal.example"
        ) == "named journal")

        let (absentFetcher, absentStore, absentSession) = makeJournalNameFetcher()
        defer { absentSession.invalidateAndCancel() }
        absentStore.enqueue(body: #"{}"#)
        let absent = await absentFetcher.fetch(baseURL: "https://journal.example")

        #expect(absent == nil)
        #expect(resolvedJournalDisplayName(
            fetchedName: absent,
            confirmedMark: .uiTestSample,
            serverURL: "https://journal.example"
        ) == "afoot unfixed")
        #expect(resolvedJournalDisplayName(
            fetchedName: nil,
            confirmedMark: nil,
            serverURL: "https://journal.example:5015"
        ) == "journal.example")
        #expect(resolvedJournalDisplayName(
            fetchedName: "",
            confirmedMark: nil,
            serverURL: "https://journal.example"
        ) == "journal.example")
    }

    @Test func bundledStubCaptureNeverQueuesAndShowsMigrationRow() {
        let state = bundledConfiguredState()
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = true
        state.microphoneAuthorizationCause = .authorized
        state.isRecording = true

        #expect(!state.captureQueuedForJournalReadiness)
        #expect(state.config.isUploadConfigured)
        #expect(state.observationRowState == .journalMigrationNeeded)
    }

    @Test func bundledStubUploadConfigurationRemainsLive() {
        let state = bundledConfiguredState(syncPaused: false)
        #expect(!state.uploadCoordinator.syncPaused)

        var config = state.config
        config.syncPaused = true
        state.updateConfig(config)

        #expect(state.uploadCoordinator.syncPaused)
        #expect(state.config.serverURL == ServiceMode.bundledServiceURL)
        #expect(state.config.serverKey == "observer-key")
    }

    @Test func bundledStubDoesNotSelfFlipStoredMode() {
        let state = bundledConfiguredState()

        _ = state.serviceNeedsAttention
        _ = state.observationRowState
        state.updateConfig(state.config)

        #expect(state.config.serviceMode == .bundled)
    }

    @Test func nilModeDefaultsToExternalWhileUnconfiguredRoutesToFork() async {
        #expect(resolvedServiceMode(for: AppConfig(serviceMode: nil)) == .external)

        var openedService = false
        await FirstLaunchRouting.route(
            config: AppConfig(serviceMode: nil),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true }
        )
        #expect(openedService)

        let discovery = await discoverLocalJournal { _ in nil }
        #expect(discovery == .fork)
    }

    @Test func firstRunLocalFoundAndNothingFoundPathsResolveToExpectedForkStates() async {
        let found = await discoverLocalJournal { _ in .uiTestSample }
        let notFound = await discoverLocalJournal { _ in nil }

        #expect(found == .found(.uiTestSample))
        #expect(notFound == .fork)
    }

    private func bundledConfiguredState(syncPaused: Bool = false) -> AppState {
        AppState.forSnapshot(config: AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "observer-key",
            syncPaused: syncPaused,
            serviceMode: .bundled
        ))
    }

    private func makeDriver() -> JournalMarkConfirmationDriver {
        JournalMarkConfirmationDriver(
            deadlineSeconds: 1,
            heldPollInterval: .milliseconds(1),
            fetchRetryInterval: .milliseconds(1)
        )
    }

    private func waitForValid(_ driver: JournalMarkConfirmationDriver) async throws {
        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run {
                if case .valid = driver.phase {
                    return true
                }
                return false
            }
        }
    }
}

private func makeIdentityFetcher() -> (JournalIdentityFetcher, ObserverURLProtocolStore, URLSession) {
    let store = ObserverURLProtocolStore()
    let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
    return (JournalIdentityFetcher(session: session), store, session)
}

private func makeJournalNameFetcher() -> (JournalNameFetcher, ObserverURLProtocolStore, URLSession) {
    let store = ObserverURLProtocolStore()
    let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
    return (JournalNameFetcher(session: session), store, session)
}

private func identityBody(committed: Bool) -> String {
    let object: [String: Any] = [
        "committed": committed,
        "instance_id": "instance-123",
        "mark": markObject(),
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private func markObject() -> [String: Any] {
    [
        "icon1": [
            "name": "bug",
            "color": ["hex": "#f59e0b"],
            "rot": 0,
            "svg": JournalMark.uiTestSample.icon1.svg,
        ],
        "icon2": [
            "name": "gem",
            "color": ["hex": "#84cc16"],
            "rot": 45,
            "svg": JournalMark.uiTestSample.icon2.svg,
        ],
        "words": ["afoot", "unfixed"],
    ]
}

private func jsonObject(_ body: String) throws -> [String: Any] {
    let data = Data(body.utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
