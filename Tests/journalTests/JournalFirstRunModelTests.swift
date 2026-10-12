// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntime
import JournalRuntimeTestSupport
import Observation
import SolstoneCore
import Testing
@testable import journal

@MainActor
@Suite("JournalFirstRunModel")
struct JournalFirstRunModelTests {
    @Test(.timeLimit(.minutes(1))) func terminationAwaitsCancelledSetupAndNeverStartsSupervisor() async throws {
        let setup = CancellationAwareSetupRunner()
        var starts = 0
        let model = JournalFirstRunModel(
            config: makeConfig(), setupRunner: setup,
            startSupervisor: { _ in starts += 1; return true }
        )
        let task = Task { await model.runSetupThenStartSupervisor() }
        await setup.waitUntilEntered()
        #expect(await setup.entered)
        await model.prepareForTermination()
        #expect(await setup.cancelled)
        await task.value
        #expect(starts == 0)
    }

    @Test func createFlowOpensTheJournalPageThenLandsHomeWhenTheJournalSaysDone() async throws {
        let trace = FirstRunTrace()
        let fixture = makeModel(
            trace: trace,
            startResults: [true],
            probeResults: [.incomplete, .incomplete, .complete]
        )

        await fixture.model.continueFromNameLocation()

        #expect(await trace.snapshot() == ["setup", "supervisor", "probe", "probe", "probe"])
        #expect(fixture.browser.opened == [URL(string: "http://127.0.0.1:5015/init")!])
        #expect(fixture.routes.contains(.ritual(.finishInBrowser)))
        #expect(fixture.model.route == .home)
        #expect(fixture.model.errorMessage == nil)
    }

    @Test func alreadyCompleteJournalGoesStraightHomeWithoutTheBrowser() async throws {
        let trace = FirstRunTrace()
        let fixture = makeModel(trace: trace, startResults: [true], probeResults: [.complete])

        await fixture.model.resumeConfiguredRoot(try makeTemporaryDirectory())

        #expect(await trace.snapshot() == ["supervisor", "probe"])
        #expect(fixture.browser.opened.isEmpty)
        #expect(fixture.model.route == .home)
    }

    @Test func resumePreSetupRunsSetupThenHandsOffToTheBrowser() async throws {
        let trace = FirstRunTrace()
        let fixture = makeModel(
            trace: trace,
            startResults: [false, true],
            probeResults: [.incomplete, .complete]
        )

        await fixture.model.resumeConfiguredRoot(try makeTemporaryDirectory())

        #expect(await trace.snapshot() == ["supervisor", "setup", "supervisor", "probe", "probe"])
        #expect(fixture.browser.opened.count == 1)
        #expect(fixture.model.route == .home)
    }

    @Test func landingHomeReadsTheIdentitySoTheMarkReachesTheIcon() async throws {
        let capture = IdentityMarkSpy()
        let fixture = makeModel(
            startResults: [true],
            probeResults: [.incomplete, .complete],
            fetchIdentity: { _ in .mark(.uiTestSample) },
            onIdentityMark: { capture.append($0) }
        )

        await fixture.model.continueFromNameLocation()

        #expect(fixture.model.route == .home)
        #expect(capture.snapshot() == [.uiTestSample])
        #expect(fixture.windowModel.markPresentation == .mark(.uiTestSample))
    }

    @Test(.timeLimit(.minutes(1))) func reopeningAfterTheTabClosesOpensThePageAgainWithoutASecondPoll() async throws {
        let gate = ProbeGate()
        let fixture = makeModel(
            startResults: [true],
            probeResults: [],
            initClient: gate,
            browserPollInterval: .seconds(30)
        )
        let run = Task { await fixture.model.continueFromNameLocation() }
        // The probe after start, then the wait's first probe; the wait then sleeps.
        await gate.waitForCalls(2)
        #expect(fixture.model.route == .ritual(.finishInBrowser))

        fixture.model.reopenInBrowser()
        try await Task.sleep(for: .milliseconds(100))

        // A second wait would probe at once; the live one is still asleep.
        #expect(await gate.calls == 2)
        #expect(fixture.browser.opened.count == 2)

        await fixture.model.prepareForTermination()
        await run.value
    }

    @Test func probeErrorsWhileWaitingKeepWaitingWithoutAnError() async throws {
        let fixture = makeModel(
            startResults: [true],
            probeResults: [.incomplete],
            probeErrors: [nil, URLError(.cannotConnectToHost), URLError(.timedOut), nil],
            trailingProbe: .complete
        )

        await fixture.model.continueFromNameLocation()

        #expect(fixture.model.route == .home)
        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.routes.contains(.ritual(.finishInBrowser)))
        #expect(fixture.browser.opened.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func terminationWhileWaitingStopsPollingAndNeverLandsHome() async throws {
        let gate = ProbeGate()
        let fixture = makeModel(startResults: [true], probeResults: [], initClient: gate)
        let run = Task { await fixture.model.continueFromNameLocation() }
        await gate.waitForCalls(2)

        await fixture.model.prepareForTermination()
        try await Task.sleep(for: .milliseconds(20))
        let after = await gate.calls
        try await Task.sleep(for: .milliseconds(100))

        // Not awaiting `run` on purpose: a wait that ignored termination would never
        // return, and this must fail rather than hang.
        #expect(await gate.calls == after)
        #expect(fixture.model.route == .ritual(.finishInBrowser))
        run.cancel()
    }

    @Test func browserThatWillNotOpenKeepsTheStateWithoutAnError() async throws {
        let fixture = makeModel(
            startResults: [true],
            probeResults: [.incomplete, .complete],
            opens: false
        )

        await fixture.model.continueFromNameLocation()

        #expect(fixture.browser.opened.count == 1)
        #expect(fixture.routes.contains(.ritual(.finishInBrowser)))
        #expect(fixture.model.errorMessage == nil)
        #expect(fixture.model.route == .home)
    }

    @Test func firstProbeFailureAfterStartIsShown() async throws {
        let fixture = makeModel(
            startResults: [true],
            probeResults: [],
            probeErrors: [URLError(.cannotConnectToHost)]
        )

        await fixture.model.continueFromNameLocation()

        #expect(fixture.model.errorMessage != nil)
        #expect(fixture.browser.opened.isEmpty)
        #expect(fixture.model.route == .ritual(.setupProgress))
    }

    @Test func discoveryHandoffQualifiesSeedsNameLocationAndConsumesOnContinue() async throws {
        let root = try makeTemporaryDirectory()
        let handoffStore = FakeFirstRunHandoffStore(handoff: discoveryHandoff(root: root))
        let fileReader = FakeFirstRunJournalFileReader()
        fileReader.directories = [root.standardizedFileURL.path, root.appendingPathComponent("config", isDirectory: true).path]
        let fixture = makeModel(
            startResults: [true],
            probeResults: [.complete],
            handoffStore: handoffStore,
            journalFileReader: fileReader,
            discoveryQualificationTimeout: 0.05
        )

        await fixture.model.decideLaunchRoute()

        #expect(fixture.model.route == .ritual(.nameLocation))
        #expect(fixture.model.journalRoot == root.standardizedFileURL)
        #expect(handoffStore.consumeCount == 0)

        await fixture.model.continueFromNameLocation()

        #expect(handoffStore.consumeCount == 1)
        #expect(fixture.setupRunner.calls == 1)
        #expect(fixture.setupRunner.rootsSnapshot == [root.standardizedFileURL])
    }

    @Test func discoveryHandoffNoLongerQualifiesConsumesAndCreatesAtDefault() async throws {
        let staleRoot = try makeTemporaryDirectory()
        let configuredRoot = try makeTemporaryDirectory()
        let config = makeConfig()
        config.journalRoot = configuredRoot
        let handoffStore = FakeFirstRunHandoffStore(handoff: discoveryHandoff(root: staleRoot))
        let fileReader = FakeFirstRunJournalFileReader()
        fileReader.directories = [staleRoot.standardizedFileURL.path]
        let fixture = makeModel(
            config: config,
            startResults: [],
            probeResults: [],
            handoffStore: handoffStore,
            journalFileReader: fileReader,
            discoveryQualificationTimeout: 0.05
        )

        await fixture.model.decideLaunchRoute()

        #expect(fixture.model.route == .ritual(.nameLocation))
        #expect(fixture.model.journalRoot == defaultJournalRoot())
        #expect(fixture.config.journalRoot == nil)
        #expect(handoffStore.consumeCount == 1)
        #expect(fixture.setupRunner.calls == 0)
    }

    @Test func discoveryHandoffStallConsumesAndCreatesAtDefault() async throws {
        let staleRoot = try makeTemporaryDirectory()
        let handoffStore = FakeFirstRunHandoffStore(handoff: discoveryHandoff(root: staleRoot))
        let fileReader = FakeFirstRunJournalFileReader()
        fileReader.directoryStalls = [staleRoot.standardizedFileURL.path]
        let fixture = makeModel(
            startResults: [],
            probeResults: [],
            handoffStore: handoffStore,
            journalFileReader: fileReader,
            discoveryQualificationTimeout: 0.05
        )
        await fixture.model.decideLaunchRoute()

        // Completion is the timeout proof: the stalled probe only returns on
        // cancellation, so reaching these asserts means qualification was cut off.
        #expect(fixture.model.route == .ritual(.nameLocation))
        #expect(fixture.model.journalRoot == defaultJournalRoot())
        #expect(handoffStore.consumeCount == 1)
    }

    @Test func migrationHandoffStillUsesAdoptRoute() async throws {
        let trace = FirstRunTrace()
        let root = try makeTemporaryDirectory()
        let handoffStore = FakeFirstRunHandoffStore(handoff: migrationHandoff(root: root))
        let fixture = makeModel(
            trace: trace,
            startResults: [false],
            probeResults: [],
            handoffStore: handoffStore
        )

        await fixture.model.decideLaunchRoute()

        #expect(fixture.model.route == .adopting)
        #expect(fixture.config.journalRoot == root.standardizedFileURL)
        #expect(handoffStore.consumeCount == 0)
        #expect(fixture.model.errorMessage != nil)
        #expect(fixture.setupRunner.rootsSnapshot == [root.standardizedFileURL])
        #expect(await trace.snapshot() == ["setup", "supervisor"])
    }

    @Test func migrationSetupFailureKeepsHandoffAndDoesNotStartSupervisor() async throws {
        let trace = FirstRunTrace()
        let root = try makeTemporaryDirectory()
        let handoffStore = FakeFirstRunHandoffStore(handoff: migrationHandoff(root: root))
        let fixture = makeModel(
            trace: trace,
            startResults: [true],
            probeResults: [],
            setupError: JournalSetupRunnerError.setupFailed(
                errorCode: "fixture",
                message: "fixture setup failed"
            ),
            handoffStore: handoffStore
        )

        await fixture.model.decideLaunchRoute()

        #expect(fixture.model.route == .adopting)
        #expect(fixture.config.journalRoot == root.standardizedFileURL)
        #expect(handoffStore.consumeCount == 0)
        #expect(fixture.model.errorMessage == "fixture setup failed")
        #expect(fixture.setupRunner.rootsSnapshot == [root.standardizedFileURL])
        #expect(await trace.snapshot() == ["setup"])
    }

    @Test func migrationRetryRepeatsSetupAndConsumesOnlyAfterStart() async throws {
        let trace = FirstRunTrace()
        let root = try makeTemporaryDirectory()
        let handoffStore = FakeFirstRunHandoffStore(handoff: migrationHandoff(root: root))
        let fixture = makeModel(
            trace: trace,
            startResults: [false, true],
            probeResults: [.complete],
            handoffStore: handoffStore
        )

        await fixture.model.decideLaunchRoute()
        #expect(handoffStore.consumeCount == 0)

        await fixture.model.decideLaunchRoute()

        #expect(fixture.model.route == .home)
        #expect(handoffStore.consumeCount == 1)
        #expect(fixture.setupRunner.rootsSnapshot == [
            root.standardizedFileURL,
            root.standardizedFileURL,
        ])
        #expect(await trace.snapshot() == [
            "setup",
            "supervisor",
            "setup",
            "supervisor",
            "probe",
        ])
    }

    @Test func corruptHandoffIsConsumedAndCreatesAtDefault() async throws {
        let configuredRoot = try makeTemporaryDirectory()
        let config = makeConfig()
        config.journalRoot = configuredRoot
        let handoffStore = FakeFirstRunHandoffStore(loadError: FakeHandoffLoadError.corrupt)
        let fixture = makeModel(
            config: config,
            startResults: [],
            probeResults: [],
            handoffStore: handoffStore
        )

        await fixture.model.decideLaunchRoute()

        #expect(fixture.model.route == .ritual(.nameLocation))
        #expect(fixture.model.route != .adopting)
        #expect(fixture.model.journalRoot == defaultJournalRoot())
        #expect(fixture.config.journalRoot == nil)
        #expect(handoffStore.consumeCount == 1)
        #expect(fixture.model.errorMessage == nil)
    }

    @Test func unknownProvenanceHandoffIsConsumedAndCreatesAtDefault() async throws {
        let unknownRoot = try makeTemporaryDirectory()
        let configuredRoot = try makeTemporaryDirectory()
        let config = makeConfig()
        config.journalRoot = configuredRoot
        let handoffStore = FakeFirstRunHandoffStore(
            handoff: handoff(root: unknownRoot, provenance: "unknown-provenance")
        )
        let fixture = makeModel(
            config: config,
            startResults: [],
            probeResults: [],
            handoffStore: handoffStore
        )

        await fixture.model.decideLaunchRoute()

        #expect(fixture.model.route == .ritual(.nameLocation))
        #expect(fixture.model.journalRoot == defaultJournalRoot())
        #expect(fixture.config.journalRoot == nil)
        #expect(handoffStore.consumeCount == 1)
        #expect(fixture.model.errorMessage == nil)
    }

}

struct FirstRunModelFixture {
    let model: JournalFirstRunModel
    let config: JournalAppConfig
    let windowModel: JournalWindowModel
    let setupRunner: FakeSetupRunner
    let initClient: FakeInitClient
    let browser: FakeBrowser
    let routeLog: RouteLog

    @MainActor var routes: [JournalFirstRunRoute] { routeLog.routes }
}

@MainActor
final class RouteLog {
    private(set) var routes: [JournalFirstRunRoute] = []

    func track(_ model: JournalFirstRunModel) {
        withObservationTracking {
            routes.append(model.route)
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                self.track(model)
            }
        }
    }
}

@MainActor
final class FakeBrowser {
    private(set) var opened: [URL] = []
    let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return result
    }
}

@MainActor
func makeModel(
    trace: FirstRunTrace = FirstRunTrace(),
    config: JournalAppConfig? = nil,
    startResults: [Bool],
    probeResults: [JournalInitSetupProbe],
    probeErrors: [Error?] = [],
    trailingProbe: JournalInitSetupProbe = .complete,
    initClient injectedInitClient: (any JournalInitClienting)? = nil,
    setupError: Error? = nil,
    handoffStore: any JournalHandoffStoring = EmptyHandoffStore(),
    journalFileReader: any OnDiskJournalFileReading = FakeFirstRunJournalFileReader(),
    discoveryQualificationTimeout: TimeInterval = 1.0,
    fetchIdentity: JournalWindowModel.IdentityFetch? = nil,
    onIdentityMark: JournalWindowModel.IdentityMarkObserver? = nil,
    opens: Bool = true,
    browserPollInterval: Duration = .milliseconds(1)
) -> FirstRunModelFixture {
    let config = config ?? makeConfig()
    let supervisor = JournalSupervisor()
    let windowModel = JournalWindowModel(
        config: config,
        supervisor: supervisor,
        fetchIdentity: fetchIdentity ?? { _ in .unavailable },
        identityRetryPause: {},
        fetchDiskUsage: { _ in 0 },
        fetchHealth: { _, _ in .unknown(JournalDiagnostic(commandLabel: "health")) },
        fetchVersion: { _, _ in nil },
        appBuild: "67",
        onIdentityMark: onIdentityMark
    )
    let setupRunner = FakeSetupRunner(trace: trace, error: setupError)
    let fakeInitClient = FakeInitClient(
        trace: trace,
        probeResults: probeResults,
        probeErrors: probeErrors,
        trailingProbe: trailingProbe
    )
    let initClient = injectedInitClient ?? fakeInitClient
    let starts = StartSequence(trace: trace, results: startResults)
    let browser = FakeBrowser(result: opens)
    let model = JournalFirstRunModel(
        config: config,
        setupRunner: setupRunner,
        initClient: initClient,
        startSupervisor: { root in
            await starts.start(root: root)
        },
        handoffStore: handoffStore,
        journalFileReader: journalFileReader,
        discoveryQualificationTimeout: discoveryQualificationTimeout,
        openURL: { browser.open($0) },
        browserPollInterval: browserPollInterval,
        windowModel: windowModel
    )
    let routeLog = RouteLog()
    routeLog.track(model)
    return FirstRunModelFixture(
        model: model,
        config: config,
        windowModel: windowModel,
        setupRunner: setupRunner,
        initClient: fakeInitClient,
        browser: browser,
        routeLog: routeLog
    )
}

@MainActor
func makeConfig() -> JournalAppConfig {
    let suiteName = "app.solstone.journal.first-run.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return JournalAppConfig(defaults: defaults, loginItemManager: FirstRunFakeLoginItemManager())
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-first-run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func defaultJournalRoot() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("journal", isDirectory: true)
        .standardizedFileURL
}

private func discoveryHandoff(root: URL) -> JournalHandoff {
    handoff(root: root, provenance: JournalHandoffProvenance.observerDiscovery)
}

private func migrationHandoff(root: URL) -> JournalHandoff {
    handoff(root: root, provenance: JournalHandoffProvenance.bundledMigration)
}

private func handoff(root: URL, provenance: String) -> JournalHandoff {
    JournalHandoff(
        journalRootPath: root.path,
        observerName: "desk journal",
        provenance: provenance,
        timestamp: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

private func stallUntilCancelled<T>(_ value: T) async -> T {
    while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return value
}

actor FirstRunTrace {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

final class StartSequence: @unchecked Sendable {
    private let trace: FirstRunTrace
    private let lock = NSLock()
    private var results: [Bool]

    init(trace: FirstRunTrace, results: [Bool]) {
        self.trace = trace
        self.results = results
    }

    func start(root: URL) async -> Bool {
        _ = root
        await trace.append("supervisor")
        return lock.withLock {
            results.isEmpty ? true : results.removeFirst()
        }
    }
}

final class FakeSetupRunner: JournalSetupRunning, @unchecked Sendable {
    private let trace: FirstRunTrace
    private let error: Error?
    private let lock = NSLock()
    private var roots: [URL] = []

    var calls: Int { lock.withLock { roots.count } }
    var rootsSnapshot: [URL] { lock.withLock { roots } }

    init(trace: FirstRunTrace, error: Error? = nil) {
        self.trace = trace
        self.error = error
    }

    func run(
        journalRoot: URL,
        skipService: Bool,
        progress: @escaping @Sendable (JournalSetupProgressEvent) async -> Void
    ) async throws -> JournalSetupResult {
        _ = skipService
        lock.withLock { roots.append(journalRoot.standardizedFileURL) }
        await trace.append("setup")
        if let error {
            throw error
        }
        await progress(.stepStarted(step: "prepare", index: 1, total: 1))
        await progress(.completed(status: "ok"))
        return try JournalSetupResult(runtime: makeRuntime(), stdoutTail: "", renderedLog: "setup ok")
    }
}

final class FakeInitClient: JournalInitClienting, @unchecked Sendable {
    private let trace: FirstRunTrace
    private let lock = NSLock()
    private var probeResults: [JournalInitSetupProbe]
    private var probeErrors: [Error?]
    private let trailingProbe: JournalInitSetupProbe

    init(
        trace: FirstRunTrace,
        probeResults: [JournalInitSetupProbe],
        probeErrors: [Error?] = [],
        trailingProbe: JournalInitSetupProbe = .complete
    ) {
        self.trace = trace
        self.probeResults = probeResults
        self.probeErrors = probeErrors
        self.trailingProbe = trailingProbe
    }

    func probeSetupComplete() async throws -> JournalInitSetupProbe {
        await trace.append("probe")
        let next: Result<JournalInitSetupProbe, Error> = lock.withLock {
            if !probeErrors.isEmpty, let error = probeErrors.removeFirst() {
                return .failure(error)
            }
            return .success(probeResults.isEmpty ? trailingProbe : probeResults.removeFirst())
        }
        return try next.get()
    }
}

/// Reports incomplete until `finish()`, counting probes, so a test can act while the app waits.
actor ProbeGate: JournalInitClienting {
    private(set) var calls = 0
    private var done = false
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func probeSetupComplete() async throws -> JournalInitSetupProbe {
        calls += 1
        let ready = waiters.filter { calls >= $0.0 }
        waiters.removeAll { calls >= $0.0 }
        ready.forEach { $0.1.resume() }
        return done ? .complete : .incomplete
    }

    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish() {
        done = true
    }
}

final class IdentityMarkSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [JournalMark] = []

    func append(_ mark: JournalMark) {
        lock.withLock { marks.append(mark) }
    }

    func snapshot() -> [JournalMark] {
        lock.withLock { marks }
    }
}

struct EmptyHandoffStore: JournalHandoffStoring {
    func load() throws -> JournalHandoff? { nil }
    func consume() throws {}
}

final class FakeFirstRunHandoffStore: JournalHandoffStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handoff: JournalHandoff?
    private var loadError: Error?
    private var consumes = 0

    var consumeCount: Int { lock.withLock { consumes } }

    init(handoff: JournalHandoff? = nil, loadError: Error? = nil) {
        self.handoff = handoff
        self.loadError = loadError
    }

    func load() throws -> JournalHandoff? {
        try lock.withLock {
            if let loadError {
                throw loadError
            }
            return handoff
        }
    }

    func consume() throws {
        lock.withLock {
            consumes += 1
            handoff = nil
            loadError = nil
        }
    }
}

final class FakeFirstRunJournalFileReader: OnDiskJournalFileReading, @unchecked Sendable {
    var directories: Set<String> = []
    var files: Set<String> = []
    var directoryEntries: [String: [String]] = [:]
    var directoryStalls: Set<String> = []

    func directoryExists(_ path: String) async -> Bool {
        if directoryStalls.contains(path) {
            return await stallUntilCancelled(false)
        }
        return directories.contains(path)
    }

    func fileExists(_ path: String) async -> Bool {
        files.contains(path) || directories.contains(path)
    }

    func contentsOfDirectory(_ path: String) async -> [String] {
        directoryEntries[path] ?? []
    }
}

enum FakeHandoffLoadError: Error {
    case corrupt
}

@MainActor
private final class FirstRunFakeLoginItemManager: LoginItemManaging {
    func register() throws {}
    func unregister() throws {}
}

private actor CancellationAwareSetupRunner: JournalSetupRunning {
    private(set) var entered = false
    private(set) var cancelled = false
    private let entry = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func waitUntilEntered() async {
        if entered { return }
        for await _ in entry.stream { return }
    }

    func run(journalRoot: URL, skipService: Bool,
             progress: @escaping @Sendable (JournalSetupProgressEvent) async -> Void) async throws -> JournalSetupResult {
        entered = true
        entry.continuation.yield(())
        entry.continuation.finish()
        do {
            try await Task.sleep(for: .seconds(120))
        } catch {
            cancelled = true
            throw error
        }
        throw CancellationError()
    }
}
