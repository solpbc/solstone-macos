// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import solstone

/// Records what the host put in the queue and answers status as the test sets it.
@MainActor
private final class FakeIntake: JournalImportIntake {
    var added: [(urls: [URL], handoff: ImportHandoff)] = []
    var statuses: [String: ImportHandoffStatus] = [:]

    func addHandedOver(_ urls: [URL], handoff: ImportHandoff) async -> ImportAddResult {
        added.append((urls, handoff))
        return ImportAddResult(outcomes: urls.enumerated().map { index, url in
            (url.lastPathComponent, url.hasDirectoryPath ? .refused(.unsupportedType) : .added(id: "item\(index)"))
        })
    }

    func handoffStatus(_ id: String) async -> ImportHandoffStatus { statuses[id] ?? .gone }
}

/// A picker the test controls: it records each request and answers when the test says.
@MainActor
private final class FakePicker {
    var requests: [JournalImportPickerRequest] = []
    private var pending: CheckedContinuation<[URL]?, Never>?

    func present(_ request: JournalImportPickerRequest, _ window: NSWindow?) async -> [URL]? {
        requests.append(request)
        return await withCheckedContinuation { pending = $0 }
    }

    var isOpen: Bool { pending != nil }

    func answer(_ urls: [URL]?) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: urls)
    }
}

@Suite("Journal import host")
@MainActor
struct JournalImportHostTests {
    private let base = URL(string: "http://127.0.0.1:52123/")!
    private let top = JournalImportSender(isMainFrame: true, scheme: "http", host: "127.0.0.1", port: 52123, isThisWebView: true)

    private func contract() throws -> JournalImportContract {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/solstone/Resources/import-host-contract.json"))
        return try #require(JournalImportContract(data: data))
    }

    private func host(_ intake: FakeIntake, picker: FakePicker? = nil, clock: @escaping () -> Date = Date.init) throws -> JournalImportHost {
        let base = self.base
        return JournalImportHost(
            contract: try contract(),
            intake: { intake },
            liveBaseURL: { base },
            presentPicker: { request, window in await (picker ?? FakePicker()).present(request, window) },
            clock: clock
        )
    }

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func decode(_ reply: String?) throws -> [String: Any] {
        let text = try #require(reply)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func thePackagedContractIsVersionTwo() throws {
        let contract = try contract()
        #expect(contract.version == 2)
        #expect(contract.pick == "import.pick")
        #expect(contract.capability == "solstoneJournalHost")
        #expect(JournalImportContract(data: Data(#"{"version":1}"#.utf8)) == nil)
    }

    @Test func onlyTheTopJournalDocumentOnTheLiveOriginIsAnswered() async throws {
        let host = try host(FakeIntake())
        let ready = json(["type": "host.ready"])
        var frame = top
        frame.isMainFrame = false
        var otherPort = top
        otherPort.port = 52124
        var otherHost = top
        otherHost.host = "outside.example"
        var otherView = top
        otherView.isThisWebView = false
        for sender in [frame, otherPort, otherHost, otherView] {
            #expect(await host.handle(body: ready, from: sender) == nil)
        }
        #expect(!host.pageAcceptsHandoff)
        #expect(await host.handle(body: ready, from: top) != nil)
        #expect(host.pageAcceptsHandoff)
        host.mainFrameCommitted()
        #expect(!host.pageAcceptsHandoff)
    }

    @Test func theScriptRunsInTheTopDocumentOfTheLiveOriginOnly() throws {
        let host = try host(FakeIntake())
        let script = try #require(host.userScript(for: base))
        #expect(script.isForMainFrameOnly)
        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.source.contains(#"["http://127.0.0.1:52123"][0]"#))
        #expect(script.source.contains("window !== window.top || location.origin !== origin"))
        #expect(JournalImportHost.documentOrigin(of: URL(string: "https://journal.example:443/x")!) == "https://journal.example")
    }

    @Test func unknownTypesAreUnsupportedAndBadRequestsRefused() async throws {
        let host = try host(FakeIntake())
        let unknown = try decode(await host.handle(body: json(["type": "future.example", "id": "unknown-1", "future": 1]), from: top))
        #expect(unknown["type"] as? String == "unsupported")
        #expect(unknown["id"] as? String == "unknown-1")
        let listContext = try decode(await host.handle(body: json(["type": "import.pick", "id": "invalid-1", "area": "quick", "multiple": true, "accept": [], "context": []]), from: top))
        #expect(listContext["outcome"] as? String == "refused")
        #expect(listContext["id"] as? String == "invalid-1")
        let huge = String(repeating: "x", count: 16_400)
        let oversized = try decode(await host.handle(body: json(["type": "import.pick", "id": "big-1", "area": "quick", "context": ["setting": huge]]), from: top))
        #expect(oversized["outcome"] as? String == "refused")
    }

    @Test func aPickQueuesWithItsContextAndAnOverlapIsBusy() async throws {
        let intake = FakeIntake()
        let picker = FakePicker()
        let host = try host(intake, picker: picker)
        let pick: [String: Any] = [
            "type": "import.pick", "id": "pick-1", "area": "document", "accept": [".txt", "text/plain"], "multiple": true,
            "future": ["ignore": true], "context": ["setting": "host conformance", "future": ["preserve": true]],
        ]
        let pending = Task { await host.handle(body: json(pick), from: top) }
        while !picker.isOpen { await Task.yield() }
        let overlap = try decode(await host.handle(body: json(pick.merging(["id": "overlap-1"]) { $1 }), from: top))
        #expect(overlap["outcome"] as? String == "busy")
        #expect(picker.requests.count == 1)
        #expect(picker.requests[0].multiple)
        #expect(picker.requests[0].types.contains(.plainText))
        picker.answer([URL(fileURLWithPath: "/tmp/sample.txt")])
        let reply = try decode(await pending.value)
        #expect(reply["type"] as? String == "import.reply")
        #expect(reply["id"] as? String == "pick-1")
        #expect(reply["outcome"] as? String == "queued")
        let items = try #require(reply["items"] as? [[String: Any]])
        #expect(items.first?["name"] as? String == "sample.txt")
        #expect(items.first?["item"] as? String == "item0")
        #expect(intake.added.first?.handoff.area == "document")
        let context = try #require(try JSONSerialization.jsonObject(with: Data(intake.added[0].handoff.context.utf8)) as? [String: Any])
        #expect(context["setting"] as? String == "host conformance")
        #expect((context["future"] as? [String: Any])?["preserve"] as? Bool == true)
    }

    @Test func dismissingThePickerIsCancelled() async throws {
        let intake = FakeIntake()
        let picker = FakePicker()
        let host = try host(intake, picker: picker)
        let pending = Task { await host.handle(body: json(["type": "import.pick", "id": "cancel-1", "area": "quick"]), from: top) }
        while !picker.isOpen { await Task.yield() }
        picker.answer(nil)
        #expect(try decode(await pending.value)["outcome"] as? String == "cancelled")
        #expect(intake.added.isEmpty)
    }

    @Test func aDropIsTakenByItsTokenOnceAndNotAfterItExpires() async throws {
        let intake = FakeIntake()
        let picker = FakePicker()
        var now = Date(timeIntervalSince1970: 1_000)
        let host = try host(intake, picker: picker, clock: { now })
        let files = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        let token = try #require(host.holdDrop(files))
        let card = try decode(await host.handle(body: json(["type": "import.pick", "id": "d1", "area": "evernote", "multiple": false, "drop": token]), from: top))
        #expect(card["outcome"] as? String == "queued")
        #expect(intake.added.last?.urls == [files[0]])
        #expect(picker.requests.isEmpty)
        let again = try decode(await host.handle(body: json(["type": "import.pick", "id": "d2", "area": "quick", "drop": token]), from: top))
        #expect(again["outcome"] as? String == "refused")
        let late = try #require(host.holdDrop(files))
        now = now.addingTimeInterval(JournalImportHost.dropLifetime + 1)
        let expired = try decode(await host.handle(body: json(["type": "import.pick", "id": "d3", "area": "quick", "drop": late]), from: top))
        #expect(expired["outcome"] as? String == "refused")
    }

    @Test func statusCarriesTheStateAndTheJournalRow() async throws {
        let intake = FakeIntake()
        intake.statuses = [
            "a": .waiting(sizeBytes: 1_024),
            "b": .uploading(sizeBytes: 2_048),
            "c": .delivered(importID: "20261120_190754"),
            "d": .attention(reason: "nope", importID: nil, reviewRequired: false, reviewExpired: false, reasonCode: "plan_failed", kind: "plan_failed", retryable: true),
            "r": .attention(reason: "waiting in your journal until you start it.", importID: "20261120_190755", reviewRequired: true, reviewExpired: false, reasonCode: "import_preview_required", kind: "body_confirmation_required", retryable: false),
            "x": .attention(reason: "waiting copy expired — send again to review", importID: "20261120_190756", reviewRequired: false, reviewExpired: true, reasonCode: "import_preview_required", kind: "body_confirmation_required", retryable: true),
        ]
        let host = try host(intake)
        func status(_ item: String) async throws -> [String: Any] {
            try decode(await host.handle(body: json(["type": "host.status", "item": item]), from: top))
        }
        let waiting = try await status("a")
        #expect(waiting["state"] as? String == "waiting")
        #expect(waiting["device_noun"] as? String == "mac")
        #expect((waiting["size_bytes"] as? NSNumber)?.int64Value == 1_024)

        let uploading = try await status("b")
        #expect(uploading["state"] as? String == "uploading")
        #expect(uploading["device_noun"] as? String == "mac")
        #expect((uploading["size_bytes"] as? NSNumber)?.int64Value == 2_048)

        let delivered = try await status("c")
        #expect(delivered["state"] as? String == "delivered")
        #expect(delivered["import_id"] as? String == "20261120_190754")

        let fault = try await status("d")
        #expect(fault["state"] as? String == "attention")
        #expect(fault["reason"] as? String == "nope")
        #expect(fault["review_required"] as? Bool == false)
        #expect(fault["review_expired"] as? Bool == false)
        #expect(fault["reason_code"] as? String == "plan_failed")
        #expect(fault["kind"] as? String == "plan_failed")
        #expect(fault["retryable"] as? Bool == true)

        let review = try await status("r")
        #expect(review["state"] as? String == "attention")
        #expect(review["review_required"] as? Bool == true)
        #expect(review["review_expired"] as? Bool == false)
        #expect(review["reason_code"] as? String == "import_preview_required")
        #expect(review["kind"] as? String == "body_confirmation_required")
        #expect(review["import_id"] as? String == "20261120_190755")
        #expect(review["retryable"] as? Bool == false)

        let expired = try await status("x")
        #expect(expired["state"] as? String == "attention")
        #expect(expired["review_required"] as? Bool == false)
        #expect(expired["review_expired"] as? Bool == true)
        #expect(expired["import_id"] as? String == "20261120_190756")
        #expect(expired["retryable"] as? Bool == true)

        #expect(try await status("e")["state"] as? String == "gone")
    }

    @Test func scriptPollsCalmlyDuringReviewRequiredAndStopsOnDeliveredOrGone() throws {
        let host = try host(FakeIntake())
        let script = try #require(host.userScript(for: base))
        #expect(script.source.contains("status.review_required === true"))
        #expect(script.source.contains("status.state === 'delivered' || status.state === 'gone'"))
        #expect(script.source.contains("allReview ? 2000 : 400"))
    }

    @Test func filterChooserPopupHasAccessibleFileTypesLabel() throws {
        let panel = NSOpenPanel()
        let chooser = JournalImportFilterChooser(panel: panel, types: [.plainText, .pdf])
        let popup = try #require(chooser.filterPopup)
        #expect(popup.accessibilityLabel() == MacStrings.macos_journalimporthost_filetypefilter())
        #expect(popup.accessibilityLabel() == "file types")
    }

    @Test func pickerFiltersMapToTypesAndUnknownOnesAreLeftOut() {
        let types = JournalImportHost.pickerTypes([".zip", "application/json", "image/*", "nonsense", ".ZIP"])
        #expect(types.contains(.zip))
        #expect(types.contains(.json))
        #expect(types.contains(.image))
        #expect(types.filter { $0 == .zip }.count == 1)
    }

    /// The journal window shows journal pages only: services, help and every other address open
    /// in the system browser, and the journal's own import page stays in the window.
    @Test func theJournalWindowShowsJournalPagesOnly() async {
        var opened: [URL] = []
        let session = JournalWindowSession(resolveHomeBase: { .url("http://127.0.0.1:52123") })
        let seam = JournalWindowWebViewSeam(session: session, openExternalURL: { opened.append($0) })
        _ = await session.open(destination: .root)
        let services = URL(string: "https://services.solstone.app/")!
        let help = URL(string: "https://solstone.app/help/import")!
        for url in [services, help] {
            #expect(seam.decideNavigationAction(requestURL: url, targetFrameIsMainFrame: true, targetFrameIsNil: false,
                                                shouldPerformDownload: false, isUserInitiated: true) == .cancel)
        }
        #expect(seam.decideNewWindowNavigationAction(requestURL: services, targetFrameIsMainFrame: nil, targetFrameIsNil: true,
                                                     shouldPerformDownload: false) == .cancel)
        #expect(opened == [services, help, services])
        #expect(seam.decideNavigationAction(requestURL: URL(string: "http://127.0.0.1:52123/app/import/")!, targetFrameIsMainFrame: true,
                                            targetFrameIsNil: false, shouldPerformDownload: false, isUserInitiated: true) == .allow)
        #expect(opened.count == 3)
    }
}

@Suite("Import handoff in the queue")
struct ImportHandoffQueueTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theHandoffSurvivesARestartAndTheReceiptNamesTheRow() throws {
        let dir = try tempDir()
        let handoff = ImportHandoff(area: "document", context: #"{"future":{"nested":true},"setting":"desk"}"#)
        let store = ImportCustodyStore(root: dir, fsync: { _ in })
        let id = try #require(store.begin())
        try Data("bytes".utf8).write(to: store.stagingPayloadURL(id))
        #expect(store.publish(id, displayName: "notes", mime: "application/octet-stream", size: 5, handoff: handoff))
        #expect(store.handoffStatus(id, missingCopyReason: "missing") == .waiting(sizeBytes: 5))

        let reopened = ImportCustodyStore(root: dir, fsync: { _ in })
        #expect(reopened.item(id)?.handoff == handoff)
        #expect(reopened.beginExchange(id, instance: "j", journalVersion: "2.0.86") == .done)
        #expect(reopened.handoffStatus(id, missingCopyReason: "missing") == .uploading(sizeBytes: 5))
        #expect(reopened.recordDelivered(id, instance: "j", importID: "20261120_190754") == .done)
        reopened.finish()
        #expect(reopened.item(id) == nil)
        #expect(reopened.handoffStatus(id, missingCopyReason: "missing") == .delivered(importID: "20261120_190754"))
        #expect(reopened.handoffStatus("unknown", missingCopyReason: "missing") == .gone)
    }

    @Test func readyToReviewHandoffTransitionsToDeliveredOrExpired() throws {
        let dir = try tempDir()
        let handoff = ImportHandoff(area: "chatgpt", context: "{}")
        let store = ImportCustodyStore(root: dir, fsync: { _ in })

        let id1 = try #require(store.begin())
        try Data("bytes1".utf8).write(to: store.stagingPayloadURL(id1))
        #expect(store.publish(id1, displayName: "export.zip", mime: "application/zip", size: 6, handoff: handoff))
        #expect(store.beginExchange(id1, instance: "j", journalVersion: "2.0.90") == .done)
        #expect(store.recordReadyToReview(
            id1,
            importID: "20261122_140000",
            error: "needs review",
            reasonCode: "import_preview_required",
            kind: "body_confirmation_required",
            instance: "j"
        ) == .done)
        #expect(store.handoffStatus(id1, missingCopyReason: "missing") == .attention(
            reason: MacStrings.macos_desktopimportpage_reviewdetail(),
            importID: "20261122_140000",
            reviewRequired: true,
            reviewExpired: false,
            reasonCode: "import_preview_required",
            kind: "body_confirmation_required",
            retryable: false
        ))
        #expect(store.reconcileConfirmed(id1, expectedImportID: "20261122_140000", expectedInstanceID: "j") == .done)
        #expect(store.handoffStatus(id1, missingCopyReason: "missing") == .delivered(importID: "20261122_140000"))

        let id2 = try #require(store.begin())
        try Data("bytes2".utf8).write(to: store.stagingPayloadURL(id2))
        #expect(store.publish(id2, displayName: "second.zip", mime: "application/zip", size: 6, handoff: handoff))
        #expect(store.beginExchange(id2, instance: "j", journalVersion: "2.0.90") == .done)
        #expect(store.recordReadyToReview(
            id2,
            importID: "20261122_140100",
            error: "needs review",
            reasonCode: "import_preview_required",
            kind: "confirmation_required",
            instance: "j"
        ) == .done)
        #expect(store.reconcileExpired(id2, expectedImportID: "20261122_140100", expectedInstanceID: "j") == .done)
        #expect(store.handoffStatus(id2, missingCopyReason: "missing") == .attention(
            reason: MacStrings.macos_desktopimportpage_reviewexpired(),
            importID: "20261122_140100",
            reviewRequired: false,
            reviewExpired: true,
            reasonCode: "import_preview_required",
            kind: "confirmation_required",
            retryable: true
        ))
    }

    @Test func theSaveCarriesTheAreaHintAndContext() throws {
        let dir = try tempDir()
        let payload = dir.appendingPathComponent("payload")
        try Data("x".utf8).write(to: payload)
        func head(_ handoff: ImportHandoff?) -> String {
            let item = ImportItemDescriptor(id: "i1", payloadURL: payload, displayName: "a.txt", mime: "text/plain", size: 1, handoff: handoff)
            return String(decoding: ImportMultipartBody(boundary: "b", item: item).prefix, as: UTF8.self)
        }
        let card = head(ImportHandoff(area: "chatgpt", context: #"{"setting":"x"}"#))
        #expect(card.contains("name=\"imported_via\"\r\n\r\nmacos\r\n"))
        #expect(card.contains("name=\"area\"\r\n\r\nchatgpt\r\n"))
        #expect(card.contains("name=\"source_hint\"\r\n\r\nchatgpt\r\n"))
        #expect(card.contains("name=\"context\"\r\n\r\n{\"setting\":\"x\"}\r\n"))
        let quick = head(ImportHandoff(area: "quick", context: "{}"))
        #expect(!quick.contains("source_hint"))
        #expect(!head(nil).contains("name=\"area\""))
    }
}
