// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntime
import JournalRuntimeTestSupport
import Testing
@testable import journal

@MainActor
@Suite("JournalWindowModel")
struct JournalWindowModelTests {
    @Test func identityFetchRunsOncePerWindowOpenAndDoesNotPoll() async throws {
        let fixture = try makeConfiguredFixture()
        defer { fixture.clear() }
        let counter = IdentityCounter(mark: .uiTestSample)
        let model = makeModel(
            config: fixture.config,
            fetchIdentity: { _ in await counter.fetch() }
        )

        model.prepareForWindowOpen()
        await model.loadForWindowOpen()
        await model.loadForWindowOpen()
        try await Task.sleep(for: .milliseconds(25))

        #expect(await counter.count == 1)
        #expect(model.identityMark == .uiTestSample)

        model.prepareForWindowOpen()
        await model.loadForWindowOpen()
        #expect(await counter.count == 2)
    }

    @Test func malformedIdentityResponseReturnsNilAndHidesMarkFallback() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: ##"{"committed":true,"mark":{"icon1":{"name":"bad","color":{"hex":"#abc"},"rot":12,"svg":""},"icon2":{"name":"bad","color":{"hex":"#abc"},"rot":12,"svg":""},"words":["only"]}}"##)
        let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
        let fetcher = JournalIdentityFetcher(session: session)
        let fixture = try makeConfiguredFixture()
        defer { fixture.clear() }
        let model = makeModel(
            config: fixture.config,
            fetchIdentity: { baseURL in await fetcher.fetch(baseURL: baseURL) },
            machineNameProvider: { "machine-name" }
        )

        await model.fetchIdentityIfNeeded()

        #expect(model.identityMark == nil)
        #expect(model.displayName == "machine-name")
    }

    @Test func displayNamePrefersConfigThenMarkThenMachineName() async throws {
        let fixture = try makeConfiguredFixture()
        defer { fixture.clear() }

        let named = makeModel(
            config: fixture.config,
            fetchConfig: { JournalConfig(journal: JournalConfigSection(name: "home base")) },
            fetchIdentity: { _ in .uiTestSample },
            machineNameProvider: { "machine-name" }
        )
        await named.loadConfigIfNeeded()
        #expect(named.displayName == "home base")

        let marked = makeModel(
            config: fixture.config,
            fetchConfig: { JournalConfig(journal: JournalConfigSection(name: "")) },
            fetchIdentity: { _ in .uiTestSample },
            machineNameProvider: { "machine-name" }
        )
        await marked.loadForWindowOpen()
        #expect(marked.displayName == "afoot · unfixed")

        let machine = makeModel(
            config: fixture.config,
            fetchConfig: { JournalConfig(journal: JournalConfigSection(name: "")) },
            fetchIdentity: { _ in nil },
            machineNameProvider: { "machine-name" }
        )
        await machine.loadForWindowOpen()
        #expect(machine.displayName == "machine-name")
    }

    @Test func runDisplayFailsClosedForLesserStates() {
        let diagnostic = JournalDiagnostic(commandLabel: "journal", outputExcerpt: "no")

        #expect(JournalRunDisplay.derive(state: .running, runtimeStatus: .running) == .running)
        #expect(JournalRunDisplay.derive(state: .running, runtimeStatus: .stopped(diagnostic)) == .stopped)
        #expect(JournalRunDisplay.derive(state: .running, runtimeStatus: .unobserved) == .unknown)
        #expect(JournalRunDisplay.derive(state: .starting, runtimeStatus: .running) == .starting)
        #expect(JournalRunDisplay.derive(state: .waitingForReadiness, runtimeStatus: .running) == .starting)
        #expect(JournalRunDisplay.derive(state: .blocked(diagnostic), runtimeStatus: .running) == .blocked)
        #expect(JournalRunDisplay.derive(state: .failed(diagnostic), runtimeStatus: .running) == .unknown)
        #expect(JournalRunDisplay.derive(state: .idle, runtimeStatus: .running) == .unknown)
    }

    @Test func postReadyStoppedStatusDropsDisplayOutOfRunning() async throws {
        let fixture = try makeConfiguredFixture()
        defer { fixture.clear() }
        let supervisor = JournalSupervisor(
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(try makeRuntime())),
            runner: MockSupervisedChildRunner(),
            readinessGate: MockJournalReadinessGate(result: .ready)
        )
        let model = makeModel(config: fixture.config, supervisor: supervisor)
        _ = await supervisor.start(journalRoot: try #require(fixture.config.journalRoot))
        supervisor.applyRuntimeStatus(.running)
        #expect(model.runDisplay == .running)

        let diagnostic = JournalDiagnostic(commandLabel: "journal", outputExcerpt: "exit")
        supervisor.applyRuntimeStatus(.stopped(diagnostic))

        #expect(model.runDisplay == .stopped)
    }

    @Test func optimisticNameWriteCommitsOnSuccessAndRevertsOnFailure() async throws {
        let fixture = try makeConfiguredFixture()
        defer { fixture.clear() }
        let success = makeModel(
            config: fixture.config,
            updateName: { name in JournalConfig(journal: JournalConfigSection(name: name)) }
        )
        success.journalName = "old"
        success.draftJournalName = "new"

        await success.saveDraftJournalName()

        #expect(success.journalName == "new")
        #expect(success.draftJournalName == "new")
        #expect(success.nameError == nil)

        let failure = makeModel(
            config: fixture.config,
            updateName: { _ in throw TestError.requested }
        )
        failure.journalName = "old"
        failure.draftJournalName = "bad"

        await failure.saveDraftJournalName()

        #expect(failure.journalName == "old")
        #expect(failure.draftJournalName == "bad")
        #expect(failure.nameError == "couldn't save name")
    }

    @Test func healthAndVersionRowsDegradeToUnknownUntilRuntimeIsAvailable() async throws {
        let fixture = try makeConfiguredFixture()
        defer { fixture.clear() }
        let supervisor = JournalSupervisor(
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(try makeRuntime())),
            runner: MockSupervisedChildRunner(),
            readinessGate: MockJournalReadinessGate(result: .ready)
        )
        let model = makeModel(
            config: fixture.config,
            supervisor: supervisor,
            fetchHealth: { _, _ in .healthy },
            fetchVersion: { _, _ in "1.2.3" },
            appVersion: "9.8.7"
        )

        await model.refreshRunState()
        #expect(model.healthDisplay == .unknown)
        #expect(model.runtimeVersion == "unknown")
        #expect(model.appVersion == "9.8.7")

        _ = await supervisor.start(journalRoot: try #require(fixture.config.journalRoot))
        await model.refreshRunState()

        #expect(model.healthDisplay == .healthy)
        #expect(model.runtimeVersion == "1.2.3")
    }

    @Test func stopJournalRefreshesHealthAndVersionRowsToUnknown() async throws {
        let fixture = try makeConfiguredFixture()
        defer { fixture.clear() }
        let supervisor = JournalSupervisor(
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(try makeRuntime())),
            runner: MockSupervisedChildRunner(),
            readinessGate: MockJournalReadinessGate(result: .ready)
        )
        let model = makeModel(
            config: fixture.config,
            supervisor: supervisor,
            fetchHealth: { _, _ in .healthy },
            fetchVersion: { _, _ in "1.2.3" }
        )
        _ = await supervisor.start(journalRoot: try #require(fixture.config.journalRoot))
        await model.refreshRunState()
        #expect(model.healthDisplay == .healthy)
        #expect(model.runtimeVersion == "1.2.3")

        model.stopJournal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline,
              !(model.healthDisplay == .unknown && model.runtimeVersion == "unknown") {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.healthDisplay == .unknown)
        #expect(model.runtimeVersion == "unknown")
    }

    @Test func unconfiguredLaunchDoesNotStartSupervisorWork() async throws {
        let fixture = makeUnconfiguredFixture()
        defer { fixture.clear() }
        let gate = MockSingleSupervisorGate()
        let supervisor = JournalSupervisor(
            gate: gate,
            materializer: MockRuntimeMaterializer(result: .success(try makeRuntime())),
            runner: MockSupervisedChildRunner(),
            readinessGate: MockJournalReadinessGate(result: .ready)
        )
        let appModel = JournalAppModel(config: fixture.config, supervisor: supervisor)

        appModel.launch()
        try await Task.sleep(for: .milliseconds(25))

        #expect(gate.prepareCalls == 0)
        #expect(appModel.windowModel.unconfiguredMessage == "nothing here yet — creating your journal comes next.")
    }

    @Test func launchAtLoginToggleUsesConfig() {
        let fixture = makeUnconfiguredFixture()
        defer { fixture.clear() }
        let model = makeModel(config: fixture.config)

        model.setLaunchAtLoginEnabled(false)
        #expect(!model.launchAtLoginEnabled)

        model.setLaunchAtLoginEnabled(true)
        #expect(model.launchAtLoginEnabled)
    }

    private func makeConfiguredFixture() throws -> AppFixture {
        let fixture = makeUnconfiguredFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-window-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixture.config.journalRoot = root
        return fixture
    }

    private func makeUnconfiguredFixture() -> AppFixture {
        let suiteName = "app.solstone.journal.window-model.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let config = JournalAppConfig(defaults: defaults, loginItemManager: WindowModelFakeLoginItemManager())
        return AppFixture(suiteName: suiteName, defaults: defaults, config: config)
    }

    private func makeModel(
        config: JournalAppConfig,
        supervisor: JournalSupervisor = JournalSupervisor(),
        fetchConfig: JournalWindowModel.ConfigFetch? = { JournalConfig(journal: JournalConfigSection(name: "")) },
        updateName: JournalWindowModel.NameUpdate? = { JournalConfig(journal: JournalConfigSection(name: $0)) },
        fetchIdentity: JournalWindowModel.IdentityFetch? = { _ in nil },
        fetchDiskUsage: JournalWindowModel.DiskUsageFetch? = { _ in 0 },
        fetchHealth: JournalWindowModel.HealthFetch? = { _, _ in .unknown(JournalDiagnostic(commandLabel: "health")) },
        fetchVersion: JournalWindowModel.VersionFetch? = { _, _ in nil },
        machineNameProvider: @escaping JournalWindowModel.MachineNameProvider = { "machine-name" },
        appVersion: String = "test-app"
    ) -> JournalWindowModel {
        JournalWindowModel(
            config: config,
            supervisor: supervisor,
            fetchConfig: fetchConfig,
            updateName: updateName,
            fetchIdentity: fetchIdentity,
            fetchDiskUsage: fetchDiskUsage,
            fetchHealth: fetchHealth,
            fetchVersion: fetchVersion,
            machineNameProvider: machineNameProvider,
            appVersion: appVersion
        )
    }
}

private enum TestError: Error {
    case requested
}

private struct AppFixture {
    let suiteName: String
    let defaults: UserDefaults
    let config: JournalAppConfig

    @MainActor
    func clear() {
        if let root = config.journalRoot {
            try? FileManager.default.removeItem(at: root)
        }
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor IdentityCounter {
    private let mark: JournalMark?
    private var calls = 0

    init(mark: JournalMark?) {
        self.mark = mark
    }

    var count: Int { calls }

    func fetch() -> JournalMark? {
        calls += 1
        return mark
    }
}

@MainActor
private final class WindowModelFakeLoginItemManager: LoginItemManaging {
    func register() throws {}
    func unregister() throws {}
}
