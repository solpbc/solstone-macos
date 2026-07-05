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
            getMarkResponses: [JournalInitMarkResponse.lockedResponse],
            handoffStore: fixture.store
        )

        await failedStart.model.adoptFromHandoff()

        #expect(fixture.store.exists())
        #expect(failedStart.config.journalRoot?.standardizedFileURL == fixture.root.standardizedFileURL)

        let successTrace = FirstRunTrace()
        let success = makeModel(
            trace: successTrace,
            config: fixture.config,
            startResults: [true],
            probeResults: [.complete],
            getMarkResponses: [JournalInitMarkResponse.lockedResponse],
            handoffStore: fixture.store
        )

        await success.model.adoptFromHandoff()

        #expect(!fixture.store.exists())
        #expect(success.model.route == .home)
        #expect(success.model.adoptMessage == JournalFirstRunCopy.adoptLandingLine)
    }

    @Test func unlockedAdoptLandsHomeHiddenWithoutNotification() async throws {
        let fixture = try makeHandoffFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.deletingLastPathComponent()) }
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

        let modelFixture = makeModel(
            trace: FirstRunTrace(),
            config: fixture.config,
            startResults: [true],
            probeResults: [.incomplete],
            getMarkResponses: [JournalInitMarkResponse.unlockedResponse],
            handoffStore: fixture.store,
            notificationCenter: center
        )

        await modelFixture.model.adoptFromHandoff()

        #expect(modelFixture.model.route == .home)
        #expect(modelFixture.model.currentMark == nil)
        #expect(modelFixture.windowModel.identityMark == nil)
        #expect(capture.snapshot().isEmpty)
        #expect(!fixture.store.exists())
    }

    @Test func blockedGateSurfacesOwnerMessageAndKeepsHandoff() async throws {
        let fixture = try makeHandoffFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base.deletingLastPathComponent()) }
        let blockage = SingleSupervisorGateBlockage.portConflict(JournalDiagnostic(
            commandLabel: "journal supervisor gate",
            outputExcerpt: "port busy"
        ))
        let supervisor = JournalSupervisor(
            gate: MockSingleSupervisorGate(result: .blocked(blockage)),
            materializer: MockRuntimeMaterializer(result: .success(try makeRuntime())),
            runner: MockSupervisedChildRunner(),
            readinessGate: MockJournalReadinessGate(result: .ready)
        )
        let windowModel = makeWindowModel(config: fixture.config, supervisor: supervisor)
        let trace = FirstRunTrace()
        let model = JournalFirstRunModel(
            config: fixture.config,
            setupRunner: FakeSetupRunner(trace: trace),
            initClient: FakeInitClient(
                trace: trace,
                probeResults: [],
                getMarkResponses: [],
                lockResponse: .lockedResponse,
                finalizeResponse: .success
            ),
            updateName: { JournalConfig(journal: JournalConfigSection(name: $0)) },
            startSupervisor: { [supervisor] root in
                await supervisor.start(journalRoot: root)
            },
            handoffStore: fixture.store,
            machineNameProvider: { "machine-name" },
            notificationCenter: NotificationCenter(),
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
        fetchConfig: { JournalConfig(journal: JournalConfigSection(name: "")) },
        updateName: { JournalConfig(journal: JournalConfigSection(name: $0)) },
        fetchIdentity: { _ in nil },
        fetchDiskUsage: { _ in 0 },
        fetchHealth: { _, _ in .unknown(JournalDiagnostic(commandLabel: "health")) },
        fetchVersion: { _, _ in nil },
        machineNameProvider: { "machine-name" },
        appVersion: "test-app"
    )
}

private struct HandoffFixture {
    let base: URL
    let root: URL
    let store: JournalHandoffStore
    let config: JournalAppConfig
}
