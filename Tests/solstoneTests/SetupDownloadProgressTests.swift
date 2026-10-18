// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import MacTestSupport
import SolstoneCore
import Testing
@testable import solstone

@Suite("Setup download progress")
@MainActor
struct SetupDownloadProgressTests {
    @Test(arguments: [false, true])
    func step5AcceptanceStartsVerificationWithoutSourceConsent(failSave: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("setup-download-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let goodStore = SetupContinuationStore(directory: directory)
        try goodStore.save(SetupContinuation(phase: .journal))
        let store = failSave ? SetupContinuationStore(directory: directory, replace: { _, _ in throw CocoaError(.fileWriteUnknown) }) : goodStore
        let mailbox = SetupMailboxStore(directory: directory)
        let handoff = SetupHandoff(handoffID: UUID(), stepIndex: 5, journalRootPath: "/fixture/journal",
            expectedInstanceID: "fixture-instance", expectedCAFingerprint: String(repeating: "a", count: 64))
        try mailbox.writeStep5(handoff)
        let reads = LockedCounter()
        let starts = LockedCounter()
        let progress = SetupDownloadProgress(read: { _ in reads.increment(); throw SetupDownloadReadError.unavailable })
        let model = SetupModel(enabled: true, continuationStore: store, mailboxDirectory: directory,
                               downloadProgress: progress)
        defer { model.stopSupportingTasks(); model.stopJournalPolling() }
        let state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false),
            setupModel: model,
            sameMachinePairStart: { _, _ in starts.increment(); return .failure(.init(kind: .transport)) },
            triggerTunnelConnectedSync: { _ in }, journalURLOpener: { _ in false }
        )
        state.configSaver = { _ in Issue.record("pairing changed source preferences") }
        model.ingestStep5IfNeeded()
        if failSave {
            #expect(model.phase == .journal)
            #expect(model.continuation?.accepted == nil)
            #expect(starts.count == 0)
        } else {
            try await waitUntil { starts.count == 1 }
            #expect(model.phase == .microphone)
            #expect(model.continuation?.accepted?.handoffID == handoff.handoffID)
            #expect(try mailbox.readStep5Receipt()?.handoffID == handoff.handoffID)
            #expect(model.setPhase(.screen))
            #expect(model.setPhase(.connection))
            #expect(starts.count == 1)
        }
        #expect(reads.count == 0)
        #expect(!state.config.isScreenCaptureEnabled)
        #expect(!state.config.isMicrophoneCaptureEnabled)
        #expect(!state.capture.isRecording)
    }

    private let wire = #"{"window_open":true,"unrelated":{"field":true},"setup":{"downloads":{"speech":{"state":"downloading","attempt_id":"speech-1","bytes_done":120,"bytes_total":100,"error":null},"thinking":{"state":"downloading","attempt_id":null,"bytes_done":8,"bytes_total":null,"error":null}},"thinking":{"capability":"ok","choice":"local"},"actions":false}}"#

    private func read(_ body: String, status: Int = 200) async throws -> (SetupDownloads, [URLRequest]) {
        let store = ObserverURLProtocolStore()
        store.registerRoute(matching: { _ in true }, statusCode: status, body: body)
        let session = BoundedLoopbackClient.makeSession(configuration: observerURLProtocolConfiguration(store: store))
        defer { session.invalidateAndCancel() }
        let value = try await SetupDownloadClient(session: session).read(baseURL: "http://127.0.0.1:18321")
        return (value, store.snapshotRequests())
    }

    @Test func actualProjectionAndBoundedRequest() async throws {
        let (value, requests) = try await read(wire)
        #expect(value.speech.bytesDone == 120)
        #expect(value.speech.bytesTotal == 100)
        #expect(value.speech.fraction == 1)
        #expect(value.thinking.bytesTotal == nil)
        #expect(value.thinking.fraction == nil)
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url?.absoluteString == "http://127.0.0.1:18321/app/home/api/first-minutes")
        #expect(request.httpMethod == "GET")
        #expect(!request.httpShouldHandleCookies)
        #expect(request.value(forHTTPHeaderField: "Cookie") != nil)
    }

    @Test(arguments: ["idle", "complete", "cancelled", "error"])
    func terminalStatesNeverAnimate(state: String) async throws {
        let body = wire.replacingOccurrences(of: "downloading", with: state)
            .replacingOccurrences(of: #""bytes_total":100"#, with: #""bytes_total":0"#)
        let (value, _) = try await read(body)
        #expect(value.speech.state.rawValue == state)
        #expect(value.speech.bytesTotal == 0)
        #expect(value.speech.fraction == nil)
    }

    @Test(arguments: [
        #"{"window_open":false}"#,
        #"{"window_open":true,"setup":{"downloads":null}}"#,
        #"{"window_open":true,"setup":null}"#,
        #"{"window_open":true,"setup":{"downloads":{}}}"#,
        "unknown-state", "negative-bytes", "malformed"
    ])
    func unavailableAndMalformedCannotBecomeReady(fixture: String) async {
        let body: String
        switch fixture {
        case "unknown-state": body = wire.replacingOccurrences(of: "downloading", with: "new-state")
        case "negative-bytes": body = wire.replacingOccurrences(of: "120", with: "-1")
        case "malformed": body = "not-json"
        default: body = fixture
        }
        do { _ = try await read(body); Issue.record("accepted unavailable progress") } catch {}
    }

    @Test(arguments: [302, 401, 403, 503])
    func refusesNonSuccess(status: Int) async {
        do { _ = try await read(wire, status: status); Issue.record("accepted HTTP failure") } catch {}
    }

    @Test(arguments: ["http://127.0.0.1:5015/init", "http://example.invalid:18321", "http://user@127.0.0.1:18321", "http://127.0.0.1:18321?key=value"])
    func refusesUnresolvedOrigins(base: String) async {
        let store = ObserverURLProtocolStore()
        store.registerRoute(matching: { _ in true }, body: wire)
        let session = BoundedLoopbackClient.makeSession(configuration: observerURLProtocolConfiguration(store: store))
        defer { session.invalidateAndCancel() }
        do { _ = try await SetupDownloadClient(session: session).read(baseURL: base); Issue.record("accepted invalid origin") } catch {}
        #expect(store.snapshotRequests().isEmpty)
    }

    private func admission(handoff: UUID, revision: String = "revision-1", generation: UInt64 = 1) -> SetupDownloadAdmission {
        .init(handoffID: handoff, credential: .init(fingerprint: "fixture-fingerprint", revision: revision),
              routeGeneration: generation, baseURL: "http://127.0.0.1:18321")
    }

    private func value() throws -> SetupDownloads {
        let root = try JSONSerialization.jsonObject(with: Data(wire.utf8)) as! [String: Any]
        let setup = root["setup"] as! [String: Any]
        return try JSONDecoder().decode(SetupDownloads.self, from: JSONSerialization.data(withJSONObject: setup["downloads"]!))
    }

    @Test(arguments: ["credential", "handoff", "route", "unavailable", "cancel", "invalidate"])
    func heldReadCannotPublishAfterAdmissionChanges(change: String) async throws {
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let entered = LockedCounter()
        let value = try value()
        let progress = SetupDownloadProgress(read: { _ in entered.increment(); await gate.wait(); return value })
        let handoff = UUID()
        var current: SetupDownloadAdmission? = admission(handoff: handoff)
        let pending = Task { await progress.refresh { current } }
        try await waitUntil { entered.count == 1 }
        switch change {
        case "credential": current = admission(handoff: handoff, revision: "revision-2")
        case "handoff": current = admission(handoff: UUID())
        case "route": current = admission(handoff: handoff, generation: 3)
        case "unavailable": current = nil
        case "cancel": pending.cancel()
        default: progress.invalidate()
        }
        gate.release()
        await pending.value
        #expect(progress.downloads == nil)
        // A fresh unchanged admission must have a positive result, too.
        current = admission(handoff: handoff, generation: 3)
        await progress.refresh { current }
        #expect(progress.downloads == value)
        current = nil
        await progress.refresh { current }
        #expect(progress.downloads == nil)
    }

    @Test func oldReadCannotClearNewProgressAfterRestart() async throws {
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let entered = LockedCounter()
        let value = try value()
        let progress = SetupDownloadProgress(read: { _ in
            entered.increment()
            if entered.count == 1 { await gate.wait() }
            return value
        })
        let context = admission(handoff: UUID())
        let old = Task { await progress.refresh { context } }
        try await waitUntil { entered.count == 1 }
        progress.invalidate()
        await progress.refresh { context }
        #expect(progress.downloads == value)
        gate.release()
        await old.value
        #expect(progress.downloads == value)
    }
}
