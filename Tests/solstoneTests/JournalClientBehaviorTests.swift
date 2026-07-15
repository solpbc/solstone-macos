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
    @Test func localLinkCommittedIdentityRegistersAndPersists() async throws {
        let (identityFetcher, identityStore, identitySession) = makeIdentityFetcher()
        defer { identitySession.invalidateAndCancel() }
        identityStore.enqueue(body: identityBody(committed: true))

        let discovery = await discoverLocalJournal { baseURL in
            await identityFetcher.fetch(baseURL: baseURL)
        }
        #expect(discovery == .found(.uiTestSample))

        let (registrationClient, registrationStore, registrationSession) = makeRegistrationClient()
        defer { registrationSession.invalidateAndCancel() }
        registrationStore.enqueue(body: fullRegistrationResponse)

        let state = AppState.forSnapshot()
        let result = await performLocalObserverRegistration(appState: state) { baseURL, descriptor in
            await registrationClient.register(baseURL: baseURL, descriptor: descriptor)
        }

        let registration = try requireRegistrationSuccess(result)
        #expect(registration.key == "observer-key")
        #expect(registration.streamName == "observer-stream")
        #expect(state.config.serverURL == ServiceMode.bundledServiceURL)
        #expect(state.config.serverKey == "observer-key")
        #expect(state.config.observerName == "observer-stream")
        #expect(state.config.serviceMode == .external)

        let request = try #require(registrationStore.snapshotRequests().first)
        #expect(request.url?.path == "/app/observer/register")
        #expect(request.httpMethod == "POST")

        let body = try #require(registrationStore.requestBodies.first.flatMap { $0 })
        let payload = try jsonObject(body)
        #expect(Set(payload.keys) == ["platform", "hostname", "stream_type", "version"])
        #expect(payload["platform"] as? String == "darwin")
        #expect((payload["hostname"] as? String)?.isEmpty == false)
        #expect(payload["stream_type"] as? String == "desktop")
        #expect((payload["version"] as? String)?.isEmpty == false)
    }

    @Test func localDiscoveryForkDoesNotRegisterWhenIdentityUncommittedOrAbsent() async {
        let uncommitted = await discoverLocalJournal { _ in nil }
        let absent = await discoverLocalJournal { _ in nil }
        let registerCalls = 0

        #expect(uncommitted == .fork)
        #expect(absent == .fork)
        #expect(registerCalls == 0)

        _ = registerCalls
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
        state.microphoneGranted = true
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

    @Test func createJournalLauncherLaunchesAppWhenPresent() {
        let appURL = URL(fileURLWithPath: "/Applications/Journal.app")
        let workspace = RecordingJournalAppWorkspace(appURL: appURL)
        LiveJournalAppLauncher(workspace: workspace).launchOrDownload()

        #expect(workspace.requestedBundleIDs == ["app.solstone.journal"])
        #expect(workspace.openedApplications == [appURL])
        #expect(workspace.openedURLs.isEmpty)
    }

    @Test func createJournalLauncherOpensDownloadWhenAppMissing() {
        let workspace = RecordingJournalAppWorkspace(appURL: nil)
        LiveJournalAppLauncher(workspace: workspace).launchOrDownload()

        #expect(workspace.requestedBundleIDs == ["app.solstone.journal"])
        #expect(workspace.openedApplications.isEmpty)
        #expect(workspace.openedURLs == [URL(string: "https://solstone.app/download")!])
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

private let fullRegistrationResponse = #"{"key":"observer-key","prefix":"captures","name":"observer-stream","ingest_url":"https://journal.example/app/observer/ingest","protocol_version":1}"#

private func makeIdentityFetcher() -> (JournalIdentityFetcher, ObserverURLProtocolStore, URLSession) {
    let store = ObserverURLProtocolStore()
    let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
    return (JournalIdentityFetcher(session: session), store, session)
}

private func makeRegistrationClient() -> (ObserverRegistrationClient, ObserverURLProtocolStore, URLSession) {
    let store = ObserverURLProtocolStore()
    let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
    return (ObserverRegistrationClient(session: session), store, session)
}

private func makeJournalNameFetcher() -> (JournalNameFetcher, ObserverURLProtocolStore, URLSession) {
    let store = ObserverURLProtocolStore()
    let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
    return (JournalNameFetcher(session: session), store, session)
}

private func requireRegistrationSuccess(
    _ result: Result<ObserverRegistration, ObserverRegistrationFailure>
) throws -> ObserverRegistration {
    switch result {
    case .success(let registration):
        return registration
    case .failure(let failure):
        throw failure
    }
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

@MainActor
private final class RecordingJournalAppWorkspace: JournalAppWorkspace {
    let appURL: URL?
    var requestedBundleIDs: [String] = []
    var openedApplications: [URL] = []
    var openedURLs: [URL] = []

    init(appURL: URL?) {
        self.appURL = appURL
    }

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        requestedBundleIDs.append(bundleIdentifier)
        return appURL
    }

    func openApplication(at appURL: URL) {
        openedApplications.append(appURL)
    }

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}
