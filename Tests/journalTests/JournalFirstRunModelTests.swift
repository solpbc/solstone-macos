// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntime
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import journal

@MainActor
@Suite("JournalFirstRunModel")
struct JournalFirstRunModelTests {
    @Test func createFlowOrdersSetupSupervisorMarkLockFinalizeThenNameWrite() async throws {
        let trace = FirstRunTrace()
        let fixture = makeModel(
            trace: trace,
            startResults: [true],
            probeResults: [.incomplete, .incomplete],
            getMarkResponses: [.unlockedResponse],
            lockResponse: .lockedResponse,
            finalizeResponse: .success
        )
        fixture.model.draftName = "desk journal"

        await fixture.model.continueFromNameLocation()
        await fixture.model.lockCurrentMark()

        #expect(await trace.snapshot() == [
            "setup",
            "supervisor",
            "probe",
            "getMark",
            "lockMark",
            "probe",
            "finalize",
            "nameWrite",
        ])
        #expect(fixture.model.route == .home)
        #expect(fixture.windowModel.identityMark == .uiTestSample)
    }

    @Test func nameWrite400IsNonFatalAndLeavesMarkFallback() async throws {
        let trace = FirstRunTrace()
        let fixture = makeModel(
            trace: trace,
            startResults: [true],
            probeResults: [.incomplete, .incomplete],
            getMarkResponses: [.unlockedResponse],
            lockResponse: .lockedResponse,
            nameUpdateError: JournalConfigClientError.serverError(400)
        )
        fixture.model.draftName = "desk journal"

        await fixture.model.continueFromNameLocation()
        await fixture.model.lockCurrentMark()

        #expect(fixture.model.route == .home)
        #expect(fixture.model.nameWriteError == JournalFirstRunCopy.nameCanBeSavedLater)
        #expect(fixture.windowModel.journalName == "")
        #expect(fixture.windowModel.draftJournalName == "desk journal")
        #expect(fixture.windowModel.displayName == "afoot · unfixed")
    }

    @Test func landingHomeKeepsLockedMarkAfterWindowLoad() async throws {
        let fixture = makeModel(
            startResults: [true],
            probeResults: [.incomplete, .incomplete],
            getMarkResponses: [.unlockedResponse],
            lockResponse: .lockedResponse
        )

        await fixture.model.continueFromNameLocation()
        await fixture.model.lockCurrentMark()
        await fixture.windowModel.loadForWindowOpen()

        #expect(fixture.model.route == .home)
        #expect(fixture.windowModel.identityMark == .uiTestSample)
        #expect(fixture.windowModel.displayName == "afoot · unfixed")
    }

    @Test func finalizeWarningsLandHome() async throws {
        let fixture = makeModel(
            startResults: [true],
            probeResults: [.incomplete, .incomplete],
            getMarkResponses: [.unlockedResponse],
            lockResponse: .lockedResponse,
            finalizeResponse: JournalInitFinalizeResponse(success: true, redirect: "/", warnings: ["note"])
        )

        await fixture.model.continueFromNameLocation()
        await fixture.model.lockCurrentMark()

        #expect(fixture.model.route == .home)
        #expect(fixture.model.finalizeWarnings == ["note"])
    }

    @Test func resumePreSetupRunsSetupThenRoutesToMarkReveal() async throws {
        let trace = FirstRunTrace()
        let fixture = makeModel(
            trace: trace,
            startResults: [false, true],
            probeResults: [.incomplete],
            getMarkResponses: [.unlockedResponse]
        )
        let root = try makeTemporaryDirectory()

        await fixture.model.resumeConfiguredRoot(root)

        #expect(await trace.snapshot() == ["supervisor", "setup", "supervisor", "probe", "getMark"])
        #expect(fixture.model.route == .ritual(.markReveal))
    }

    @Test func resumePostSetupPreLockRoutesToMarkReveal() async throws {
        let trace = FirstRunTrace()
        let fixture = makeModel(
            trace: trace,
            startResults: [true],
            probeResults: [.incomplete],
            getMarkResponses: [.unlockedResponse]
        )

        await fixture.model.resumeConfiguredRoot(try makeTemporaryDirectory())

        #expect(await trace.snapshot() == ["supervisor", "probe", "getMark"])
        #expect(fixture.model.route == .ritual(.markReveal))
    }

    @Test func resumePostLockPreFinalizeAutoFinalizesThenLandsHome() async throws {
        let trace = FirstRunTrace()
        let fixture = makeModel(
            trace: trace,
            startResults: [true],
            probeResults: [.incomplete, .incomplete],
            getMarkResponses: [.lockedResponse]
        )

        await fixture.model.resumeConfiguredRoot(try makeTemporaryDirectory())

        #expect(await trace.snapshot() == ["supervisor", "probe", "getMark", "probe", "finalize", "nameWrite"])
        #expect(fixture.initClient.finalizeCalls == 1)
        #expect(fixture.model.route == .home)
    }

    @Test func resumeCompleteLandsHomeWithoutRepostingFinalize() async throws {
        let fixture = makeModel(
            startResults: [true],
            probeResults: [.complete],
            getMarkResponses: [.lockedResponse]
        )

        await fixture.model.resumeConfiguredRoot(try makeTemporaryDirectory())

        #expect(fixture.initClient.finalizeCalls == 0)
        #expect(fixture.model.route == .home)
    }

    @Test func journalMarkLockedPostsExactlyOnceWithValidatedMark() async throws {
        let center = NotificationCenter()
        let capture = NotificationCapture()
        let token = center.addObserver(
            forName: .journalMarkLocked,
            object: nil,
            queue: nil
        ) { notification in
            if let mark = JournalMarkLockedNotification.mark(from: notification) {
                capture.append(mark)
            }
        }
        defer { center.removeObserver(token) }

        let fixture = makeModel(
            startResults: [true, true],
            probeResults: [.incomplete, .incomplete, .complete],
            getMarkResponses: [.unlockedResponse, .lockedResponse],
            lockResponse: .lockedResponse,
            notificationCenter: center
        )

        await fixture.model.continueFromNameLocation()
        await fixture.model.lockCurrentMark()
        await fixture.model.resumeConfiguredRoot(try makeTemporaryDirectory())

        #expect(capture.snapshot() == [.uiTestSample])
    }

    @Test func finalizeRetrySkipsSecondPostWhenProbeReportsComplete() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(statusCode: 200)
        store.enqueue(statusCode: 500, body: #"{"error":"lost response"}"#)
        store.enqueue(statusCode: 302)
        let client = JournalInitClient(
            sessionConfiguration: observerURLProtocolConfiguration(store: store)
        )
        let fixture = makeModel(
            startResults: [],
            probeResults: [],
            initClient: client
        )
        fixture.config.journalRoot = try makeTemporaryDirectory()
        fixture.model.currentMark = .uiTestSample
        fixture.model.markLocked = true

        await fixture.model.finalizeAndLandHome()
        await fixture.model.finalizeAndLandHome()

        #expect(store.snapshotRequests().map { $0.url?.path } == [
            "/init",
            "/init/finalize",
            "/init",
        ])
        #expect(fixture.model.route == .home)
        #expect(fixture.windowModel.identityMark == .uiTestSample)
    }
}

struct FirstRunModelFixture {
    let model: JournalFirstRunModel
    let config: JournalAppConfig
    let windowModel: JournalWindowModel
    let setupRunner: FakeSetupRunner
    let initClient: FakeInitClient
}

@MainActor
func makeModel(
    trace: FirstRunTrace = FirstRunTrace(),
    config: JournalAppConfig? = nil,
    startResults: [Bool],
    probeResults: [JournalInitSetupProbe],
    initClient injectedInitClient: (any JournalInitClienting)? = nil,
    getMarkResponses: [JournalInitMarkResponse] = [],
    lockResponse: JournalInitMarkResponse = .lockedResponse,
    finalizeResponse: JournalInitFinalizeResponse = .success,
    nameUpdateError: Error? = nil,
    handoffStore: any JournalHandoffStoring = EmptyHandoffStore(),
    notificationCenter: NotificationCenter = NotificationCenter()
) -> FirstRunModelFixture {
    let config = config ?? makeConfig()
    let supervisor = JournalSupervisor()
    let windowModel = JournalWindowModel(
        config: config,
        supervisor: supervisor,
        fetchConfig: { JournalConfig(journal: JournalConfigSection(name: "")) },
        updateName: { JournalConfig(journal: JournalConfigSection(name: $0)) },
        fetchIdentity: { _ in nil },
        fetchDiskUsage: { _ in 0 },
        fetchHealth: { _, _ in .unknown(JournalDiagnostic(commandLabel: "health")) },
        fetchVersion: { _, _ in nil },
        machineNameProvider: { "machine-name" },
        appVersion: "test-app"
    )
    let setupRunner = FakeSetupRunner(trace: trace)
    let fakeInitClient = FakeInitClient(
        trace: trace,
        probeResults: probeResults,
        getMarkResponses: getMarkResponses,
        lockResponse: lockResponse,
        finalizeResponse: finalizeResponse
    )
    let initClient = injectedInitClient ?? fakeInitClient
    let starts = StartSequence(trace: trace, results: startResults)
    let model = JournalFirstRunModel(
        config: config,
        setupRunner: setupRunner,
        initClient: initClient,
        updateName: { name in
            await trace.append("nameWrite")
            if let nameUpdateError {
                throw nameUpdateError
            }
            return JournalConfig(journal: JournalConfigSection(name: name))
        },
        startSupervisor: { root in
            await starts.start(root: root)
        },
        handoffStore: handoffStore,
        machineNameProvider: { "machine-name" },
        notificationCenter: notificationCenter,
        windowModel: windowModel
    )
    return FirstRunModelFixture(
        model: model,
        config: config,
        windowModel: windowModel,
        setupRunner: setupRunner,
        initClient: fakeInitClient
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
    private let lock = NSLock()
    private var roots: [URL] = []

    var calls: Int { lock.withLock { roots.count } }

    init(trace: FirstRunTrace) {
        self.trace = trace
    }

    func run(
        journalRoot: URL,
        skipService: Bool,
        progress: @escaping @Sendable (JournalSetupProgressEvent) async -> Void
    ) async throws -> JournalSetupResult {
        _ = skipService
        lock.withLock { roots.append(journalRoot.standardizedFileURL) }
        await trace.append("setup")
        await progress(.stepStarted(step: "prepare", index: 1, total: 1))
        await progress(.completed(status: "ok"))
        return try JournalSetupResult(runtime: makeRuntime(), stdoutTail: "", renderedLog: "setup ok")
    }
}

final class FakeInitClient: JournalInitClienting, @unchecked Sendable {
    private let trace: FirstRunTrace
    private let lock = NSLock()
    private var probeResults: [JournalInitSetupProbe]
    private var getMarkResponses: [JournalInitMarkResponse]
    private let lockResponse: JournalInitMarkResponse
    private let finalizeResponse: JournalInitFinalizeResponse
    private var finalizes = 0

    var finalizeCalls: Int { lock.withLock { finalizes } }

    init(
        trace: FirstRunTrace,
        probeResults: [JournalInitSetupProbe],
        getMarkResponses: [JournalInitMarkResponse],
        lockResponse: JournalInitMarkResponse,
        finalizeResponse: JournalInitFinalizeResponse
    ) {
        self.trace = trace
        self.probeResults = probeResults
        self.getMarkResponses = getMarkResponses
        self.lockResponse = lockResponse
        self.finalizeResponse = finalizeResponse
    }

    func getMark() async throws -> JournalInitMarkResponse {
        await trace.append("getMark")
        return lock.withLock {
            getMarkResponses.isEmpty ? .unlockedResponse : getMarkResponses.removeFirst()
        }
    }

    func regenerateMark() async throws -> JournalInitMarkResponse {
        await trace.append("regenerateMark")
        return .unlockedResponse
    }

    func lockMark() async throws -> JournalInitMarkResponse {
        await trace.append("lockMark")
        return lockResponse
    }

    func finalize(body: JournalInitFinalizeRequest) async throws -> JournalInitFinalizeResponse {
        _ = body
        await trace.append("finalize")
        lock.withLock { finalizes += 1 }
        return finalizeResponse
    }

    func probeSetupComplete() async throws -> JournalInitSetupProbe {
        await trace.append("probe")
        return lock.withLock {
            probeResults.isEmpty ? .complete : probeResults.removeFirst()
        }
    }

}

struct EmptyHandoffStore: JournalHandoffStoring {
    func exists() -> Bool { false }
    func load() throws -> JournalHandoff? { nil }
    func consume() throws {}
}

final class NotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [JournalMark] = []

    func append(_ mark: JournalMark) {
        lock.withLock { marks.append(mark) }
    }

    func snapshot() -> [JournalMark] {
        lock.withLock { marks }
    }
}

@MainActor
private final class FirstRunFakeLoginItemManager: LoginItemManaging {
    func register() throws {}
    func unregister() throws {}
}

extension JournalInitMarkResponse {
    static let unlockedResponse = JournalInitMarkResponse(mark: .uiTestSample, locked: false)
    static let lockedResponse = JournalInitMarkResponse(mark: .uiTestSample, locked: true)
}

extension JournalInitFinalizeResponse {
    static let success = JournalInitFinalizeResponse(success: true, redirect: "/", warnings: [])
}
