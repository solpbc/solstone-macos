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
@Suite("JournalHandoffStore")
struct JournalHandoffStoreTests {
    @Test func consumeOnSuccessfulAdoptOnly() async throws {
        let fixture = try makeHandoffFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.deletingLastPathComponent()) }

        let failedStartTrace = FirstRunTrace()
        let failedStart = makeModel(
            trace: failedStartTrace,
            config: fixture.config,
            startResults: [false],
            probeResults: [.complete],
            handoffStore: fixture.store
        )

        await failedStart.model.adoptFromHandoff()

        #expect(fixture.store.exists())
        #expect(failedStart.config.journalRoot?.standardizedFileURL == fixture.root.standardizedFileURL)
        #expect(await failedStartTrace.snapshot() == ["setup", "supervisor"])

        let successTrace = FirstRunTrace()
        let success = makeModel(
            trace: successTrace,
            config: fixture.config,
            startResults: [true],
            probeResults: [.complete],
            handoffStore: fixture.store
        )

        await success.model.adoptFromHandoff()

        #expect(!fixture.store.exists())
        #expect(success.model.route == .home)
        #expect(success.model.adoptMessage == JournalFirstRunCopy.adoptLandingLine)
        #expect(await successTrace.snapshot() == ["setup", "supervisor", "probe"])
        #expect(success.browser.opened.isEmpty)
    }

    @Test func incompleteAdoptHandsOffToTheBrowserThenLandsHome() async throws {
        let fixture = try makeHandoffFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.deletingLastPathComponent()) }
        let trace = FirstRunTrace()
        let modelFixture = makeModel(
            trace: trace,
            config: fixture.config,
            startResults: [true],
            probeResults: [.incomplete, .incomplete, .complete],
            handoffStore: fixture.store
        )

        await modelFixture.model.adoptFromHandoff()

        #expect(!fixture.store.exists())
        #expect(await trace.snapshot() == ["setup", "supervisor", "probe", "probe", "probe"])
        #expect(modelFixture.browser.opened == [URL(string: "http://127.0.0.1:5015/init")!])
        #expect(modelFixture.routes.contains(.ritual(.finishInBrowser)))
        #expect(modelFixture.model.route == .home)
        #expect(modelFixture.model.adoptMessage == JournalFirstRunCopy.adoptLandingLine)
    }

    @Test func blockedGateSurfacesOwnerMessageAndKeepsHandoff() async throws {
        let fixture = try makeHandoffFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.deletingLastPathComponent()) }
        let blockage = SingleSupervisorGateBlockage.portConflict(JournalDiagnostic(
            commandLabel: "journal supervisor gate",
            outputExcerpt: "port busy"
        ))
        let supervisor = JournalSupervisor(
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(try makeRuntime())),
            runner: MockSupervisedChildRunner(startError: SupervisedJournalRunnerError.gateBlocked(blockage)),
            readinessGate: MockJournalReadinessGate(result: .ready)
        )
        _ = configureInMemoryReceiptContext(supervisor)
        let windowModel = makeWindowModel(config: fixture.config, supervisor: supervisor)
        let trace = FirstRunTrace()
        let model = JournalFirstRunModel(
            config: fixture.config,
            setupRunner: FakeSetupRunner(trace: trace),
            initClient: FakeInitClient(trace: trace, probeResults: []),
            startSupervisor: { [supervisor] root in
                await supervisor.start(journalRoot: root)
            },
            handoffStore: fixture.store,
            windowModel: windowModel
        )

        await model.adoptFromHandoff()

        #expect(model.errorMessage == blockage.ownerMessage)
        #expect(fixture.store.exists())
        #expect(fixture.config.journalRoot?.standardizedFileURL == fixture.root.standardizedFileURL)
    }

    @Test func adoptPathDoesNotMoveOrCopyData() throws {
        let modelSource = try String(contentsOfFile: "Sources/journal/JournalFirstRunModel.swift", encoding: .utf8)
        let storeSource = try String(contentsOfFile: "Sources/journal/JournalHandoffStore.swift", encoding: .utf8)
        #expect(!containsFileMovementCall(modelSource, name: "moveItem"))
        #expect(!containsFileMovementCall(modelSource, name: "copyItem"))
        #expect(!containsFileMovementCall(storeSource, name: "moveItem"))
        #expect(!containsFileMovementCall(storeSource, name: "copyItem"))
    }

    private func makeHandoffFixture() throws -> HandoffFixture {
        let baseParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-handoff-store-\(UUID().uuidString)", isDirectory: true)
        let base = baseParent.appendingPathComponent("Application Support", isDirectory: true)
        let root = baseParent.appendingPathComponent("journal-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = JournalHandoffFile.url(applicationSupportBaseURL: base)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handoff = JournalHandoff(
            journalRootPath: root.path,
            observerName: "desk journal",
            provenance: "test",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try JSONEncoder().encode(handoff).write(to: url)
        let store = JournalHandoffStore(applicationSupportBaseURL: base)
        let config = makeConfig()
        return HandoffFixture(base: base, root: root, store: store, config: config)
    }
}

private func containsFileMovementCall(_ source: String, name: String) -> Bool {
    source.range(
        of: #"\b\#(name)\s*\("#,
        options: .regularExpression
    ) != nil
}

@MainActor
private func makeWindowModel(config: JournalAppConfig, supervisor: JournalSupervisor) -> JournalWindowModel {
    JournalWindowModel(
        config: config,
        supervisor: supervisor,
        fetchIdentity: { _ in .unavailable },
        fetchDiskUsage: { _ in 0 },
        fetchHealth: { _, _ in .unknown(JournalDiagnostic(commandLabel: "health")) },
        fetchVersion: { _, _ in nil },
        appBuild: "67"
    )
}

private struct HandoffFixture {
    let base: URL
    let root: URL
    let store: JournalHandoffStore
    let config: JournalAppConfig
}
