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

    private func job(_ state: SetupDownloadState, attempt: String? = nil, code: String? = nil) -> SetupDownloadJob {
        SetupDownloadJob(state: state, attemptID: attempt, bytesDone: 0, bytesTotal: nil,
                         error: code.map { .init(code: $0, detail: "fixture detail") })
    }

    private func downloads(speech: SetupDownloadJob? = nil, thinking: SetupDownloadJob) -> SetupDownloads {
        SetupDownloads(speech: speech ?? job(.complete), thinking: thinking)
    }

    @Test func thinkingControlsFollowItsState() {
        #expect(downloads(thinking: job(.downloading, attempt: "attempt-1")).thinkingAction == .cancelThinking(attemptID: "attempt-1"))
        #expect(downloads(thinking: job(.downloading)).thinkingAction == nil)
        #expect(downloads(thinking: job(.downloading, attempt: "")).thinkingAction == nil)
        #expect(downloads(thinking: job(.error, code: "download_failed")).thinkingAction == .startThinking)
        #expect(downloads(thinking: job(.cancelled, attempt: "attempt-1")).thinkingAction == .startThinking)
        #expect(downloads(thinking: job(.complete)).thinkingAction == nil)
        #expect(downloads(thinking: job(.idle)).thinkingAction == nil)
    }

    @Test func idleThinkingIsHiddenAndOtherStatesShow() {
        #expect(!downloads(thinking: job(.idle)).showsThinking)
        for state in [SetupDownloadState.downloading, .complete, .cancelled, .error] {
            #expect(downloads(thinking: job(state)).showsThinking, "\(state)")
        }
    }

    @Test func speechRetryOnlyAfterARetryableFailure() {
        #expect(downloads(speech: job(.error, code: "download_failed"), thinking: job(.idle)).speechAction == .retrySpeech)
        #expect(downloads(speech: job(.error), thinking: job(.idle)).speechAction == .retrySpeech)
        #expect(downloads(speech: job(.error, code: "speech_package_unavailable"), thinking: job(.idle)).speechAction == nil)
        for state in [SetupDownloadState.idle, .downloading, .complete, .cancelled] {
            #expect(downloads(speech: job(state), thinking: job(.idle)).speechAction == nil, "\(state)")
        }
    }

    @Test(arguments: [
        (SetupDownloadAction.cancelThinking(attemptID: "attempt-7"),
         ["action": "cancel_thinking_download", "attempt_id": "attempt-7"]),
        (.startThinking, ["action": "start_thinking_download"]),
        (.retrySpeech, ["action": "retry_speech_download"])
    ])
    func actionPostsToJournalAppsOwnListener(action: SetupDownloadAction, expected: [String: String]) async throws {
        let store = ObserverURLProtocolStore()
        store.registerRoute(matching: { _ in true }, statusCode: 503,
                            body: #"{"error":"retry pending","reason_code":"speech_admission_pending","detail":"fixture"}"#)
        let session = BoundedLoopbackClient.makeSession(configuration: observerURLProtocolConfiguration(store: store))
        defer { session.invalidateAndCancel() }
        await SetupActionClient(session: session).send(action)
        let requests = store.snapshotRequests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url?.absoluteString == "http://127.0.0.1:5015/init/api/action")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let body = try #require(store.snapshotRequestBodyData().first ?? nil)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == expected)
    }

    private func actionHarness(
        reads: [SetupDownloads]
    ) -> (SetupDownloadProgress, LockedArray<SetupDownloadAction>, LockedCounter) {
        let queue = LockedArray(reads)
        let last = reads.last!
        let readCount = LockedCounter()
        let sent = LockedArray<SetupDownloadAction>([])
        let progress = SetupDownloadProgress(
            read: { _ in readCount.increment(); return queue.removeFirst(default: last) },
            send: { sent.append($0) }
        )
        return (progress, sent, readCount)
    }

    @Test func actionWaitsForAMatchingDirectListenerThenRereads() async throws {
        let shown = downloads(thinking: job(.downloading, attempt: "attempt-1"))
        let (progress, sent, readCount) = actionHarness(reads: [shown, downloads(thinking: job(.cancelled, attempt: "attempt-1"))])
        let context = admission(handoff: UUID())
        let checks = LockedCounter()
        await progress.refresh(admission: { context }, verifyDirect: { _ in checks.increment(); return true })
        #expect(progress.actionsEnabled)
        await progress.perform(.cancelThinking(attemptID: "attempt-1"), admission: { context },
                               verifyDirect: { _ in checks.increment(); return true })
        #expect(sent.all == [.cancelThinking(attemptID: "attempt-1")])
        #expect(checks.count == 2)
        #expect(readCount.count == 2)
        #expect(progress.downloads?.thinkingAction == .startThinking)
        #expect(progress.actionsEnabled)
    }

    @Test func staleCancelIsNeverSentForANewerAttempt() async throws {
        let (progress, sent, _) = actionHarness(reads: [
            downloads(thinking: job(.downloading, attempt: "attempt-1")),
            downloads(thinking: job(.downloading, attempt: "attempt-2"))
        ])
        let context = admission(handoff: UUID())
        await progress.refresh(admission: { context }, verifyDirect: { _ in true })
        await progress.refresh(admission: { context }, verifyDirect: { _ in true })
        await progress.perform(.cancelThinking(attemptID: "attempt-1"), admission: { context }, verifyDirect: { _ in true })
        #expect(sent.all.isEmpty)
        await progress.perform(.cancelThinking(attemptID: "attempt-2"), admission: { context }, verifyDirect: { _ in true })
        #expect(sent.all == [.cancelThinking(attemptID: "attempt-2")])
    }

    @Test func mismatchedDirectListenerKeepsControlsDisabledAndSendsNothing() async throws {
        let (progress, sent, _) = actionHarness(reads: [downloads(speech: job(.error, code: "download_failed"), thinking: job(.idle))])
        let context = admission(handoff: UUID())
        await progress.refresh(admission: { context }, verifyDirect: { _ in false })
        #expect(!progress.actionsEnabled)
        await progress.perform(.retrySpeech, admission: { context }, verifyDirect: { _ in true })
        #expect(sent.all.isEmpty)

        // A listener that stops matching between the read and the click is refused, too.
        await progress.refresh(admission: { context }, verifyDirect: { _ in true })
        #expect(progress.actionsEnabled)
        await progress.perform(.retrySpeech, admission: { context }, verifyDirect: { _ in false })
        #expect(sent.all.isEmpty)
        #expect(!progress.actionsEnabled)
    }

    @Test func nothingToOfferMeansNoDirectCheck() async throws {
        let (progress, _, _) = actionHarness(reads: [downloads(thinking: job(.idle))])
        let checks = LockedCounter()
        await progress.refresh(admission: { self.admission(handoff: UUID()) }, verifyDirect: { _ in checks.increment(); return true })
        #expect(checks.count == 0)
        #expect(!progress.actionsEnabled)
    }

    @Test func unavailableOnlyAfterAReadFails() async throws {
        let progress = SetupDownloadProgress(read: { _ in throw SetupDownloadReadError.unavailable })
        #expect(!progress.readFailed)
        await progress.refresh { nil }
        #expect(!progress.readFailed)
        await progress.refresh { self.admission(handoff: UUID()) }
        #expect(progress.readFailed)
        progress.invalidate()
        #expect(!progress.readFailed)
    }
}
