// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import solstone

@Suite("SyncService", .serialized)
struct SyncServiceTests {
    private let store = ObserverURLProtocolStore()

    @Test func relayResolverRoutesGetAndUploadToLoopbackTarget() async throws {
        resetSyncedDaysCache()
        store.reset()
        store.enqueue(statusCode: 200, body: "[]")
        store.enqueue(statusCode: 200, body: "{}")
        let root = try makeTempDirectory("sync-relay")
        let segment = try makeSegment(root: root)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24682") }
        )
        await configure(service)

        await service.sync()

        let requests = store.snapshotRequests()
        let get = try #require(requests.first)
        let post = try #require(requests.dropFirst().first)
        #expect(get.httpMethod == "GET")
        #expect(get.url?.host == "127.0.0.1")
        #expect(get.url?.port == 24682)
        #expect(get.url?.path == "/app/devices/ingest/segments/\(dayString(for: segment.date))")
        #expect(post.httpMethod == "POST")
        #expect(post.url?.host == "127.0.0.1")
        #expect(post.url?.port == 24682)
        #expect(post.url?.path == "/app/devices/ingest")
    }

    @Test func staticResolverRoutesGetAndUploadToExternalTarget() async throws {
        resetSyncedDaysCache()
        store.reset()
        store.enqueue(statusCode: 200, body: "[]")
        store.enqueue(statusCode: 200, body: "{}")
        let root = try makeTempDirectory("sync-static")
        let segment = try makeSegment(root: root)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("https://journal.example:9443") }
        )
        await configure(service)

        await service.sync()

        let requests = store.snapshotRequests()
        let get = try #require(requests.first)
        let post = try #require(requests.dropFirst().first)
        #expect(get.url?.host == "journal.example")
        #expect(get.url?.port == 9443)
        #expect(get.url?.path == "/app/devices/ingest/segments/\(dayString(for: segment.date))")
        #expect(post.url?.host == "journal.example")
        #expect(post.url?.port == 9443)
        #expect(post.url?.path == "/app/devices/ingest")
    }

    @Test func heldBeforeServerSegmentsMakesNoRequestAndNextURLProceeds() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-held")
        let segment = try makeSegment(root: root)
        let resolver = ResolverScript([.held])
        let service = makeService(root: root, resolver: resolver.resolver)
        let recorder = SyncProgressRecorder()
        let eventTask = await recordProgress(from: service, into: recorder)
        defer { eventTask.cancel() }
        await configure(service)

        await service.sync()

        #expect(store.snapshotRequests().isEmpty)
        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(100)) {
            await recorder.containsAwaitingTunnel()
        }

        store.enqueue(statusCode: 200, body: "[]")
        store.enqueue(statusCode: 200, body: "{}")
        await resolver.replace(with: [.url("http://127.0.0.1:24683")])
        await service.sync()

        let requests = store.snapshotRequests()
        #expect(requests.count == 2)
        #expect(requests.last?.url?.path == "/app/devices/ingest")
    }

    @Test func sameJournalPortChangeRetriesAgainstNewLoopbackPort() async throws {
        resetSyncedDaysCache()
        store.reset()
        store.enqueue(statusCode: 200, body: "[]")
        store.enqueue(statusCode: 500, body: "temporary")
        store.enqueue(statusCode: 200, body: "{}")
        let root = try makeTempDirectory("sync-port-change")
        _ = try makeSegment(root: root)
        let resolver = HomeBaseURLResolver {
            let uploads = store.snapshotRequests()
                .filter { $0.url?.path == "/app/devices/ingest" }
                .count
            return .url(uploads == 0 ? "http://127.0.0.1:1111" : "http://127.0.0.1:2222")
        }
        let service = makeService(root: root, resolver: resolver, retryDelays: [0])
        await configure(service)

        await service.sync()

        let requests = store.snapshotRequests()
        let uploadRequests = requests.filter { $0.url?.path == "/app/devices/ingest" }
        #expect(uploadRequests.count == 2)
        #expect(uploadRequests.first?.url?.port == 1111)
        #expect(uploadRequests.last?.url?.port == 2222)
    }

    @Test func differentJournalIdentityAbortsRetryWithConfigChanged() async throws {
        resetSyncedDaysCache()
        store.reset()
        store.enqueue(statusCode: 200, body: "[]")
        store.enqueue(statusCode: 500, body: "temporary")
        let root = try makeTempDirectory("sync-config-change")
        _ = try makeSegment(root: root)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24684") },
            retryDelays: [1]
        )
        let recorder = SyncProgressRecorder()
        let eventTask = await recordProgress(from: service, into: recorder)
        defer { eventTask.cancel() }
        await configure(service, configuredServerURL: "https://configured-a.example")

        let syncTask = Task {
            await service.sync()
        }
        await store.waitForRequestCount(2)
        await configure(service, configuredServerURL: "https://configured-b.example")
        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(100)) {
            await recorder.containsConfigChangedFailure()
        }
        await syncTask.value

        #expect(await recorder.containsConfigChangedFailure())
        #expect(store.snapshotRequests().count == 2)
    }

    @Test func missingStatusRetainsSegmentAndNeedsUpload() async throws {
        try await assertUnprovenListingRetainsAndUploads(
            testName: "sync-missing-status",
            listingStatus: "missing",
            shaOverride: nil
        )
    }

    @Test func shaMismatchRetainsSegmentAndNeedsUpload() async throws {
        try await assertUnprovenListingRetainsAndUploads(
            testName: "sync-sha-mismatch",
            listingStatus: "present",
            shaOverride: "not-the-local-sha"
        )
    }

    @Test func listingWithoutStatusRetainsSegmentAndNeedsUpload() async throws {
        try await assertUnprovenListingRetainsAndUploads(
            testName: "sync-missing-listing-status",
            listingStatus: nil,
            shaOverride: nil
        )
    }

    @Test func provenListingAllowsCleanupDeletion() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-proof-cleanup")
        let segment = try makeSegment(root: root, date: oldDateForRetention())
        let sha = try sha256(of: segment.url.appendingPathComponent("\(segment.url.lastPathComponent)_audio.m4a"))
        let listing = listingJSON(
            key: segment.url.lastPathComponent,
            submittedName: "\(segment.url.lastPathComponent)_audio.m4a",
            sha: sha,
            status: "present"
        )
        store.enqueue(statusCode: 200, body: listing)
        store.enqueue(statusCode: 200, body: listing)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24685") })
        await configure(service, cacheRetentionDays: 0)

        await service.sync()

        let requests = store.snapshotRequests()
        let uploadRequestCount = requests.filter { $0.url?.path == "/app/devices/ingest" }.count
        let listingRequestCount = requests.filter {
            $0.url?.path.contains("/app/devices/ingest/segments/") == true
        }.count
        #expect(!FileManager.default.fileExists(atPath: segment.url.path))
        #expect(uploadRequestCount == 0)
        #expect(listingRequestCount == 2)
    }

    @Test func uploadExcludedOnlySegmentIsRetainedByCleanup() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-upload-excluded-cleanup")
        let segment = try makeSegmentWithOnlyUploadExcludedFile(root: root, date: oldDateForRetention())
        let listing = #"[{"key":"\#(segment.url.lastPathComponent)","files":[]}]"#
        store.enqueue(statusCode: 200, body: listing)
        store.enqueue(statusCode: 200, body: listing)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24692") })
        let recorder = SyncProgressRecorder()
        let eventTask = await recordProgress(from: service, into: recorder)
        defer { eventTask.cancel() }
        await configure(service, cacheRetentionDays: 0)

        await service.sync()

        let requests = store.snapshotRequests()
        let uploadRequestCount = requests.filter { $0.url?.path == "/app/devices/ingest" }.count
        let listingRequestCount = requests.filter {
            $0.url?.path.contains("/app/devices/ingest/segments/") == true
        }.count
        #expect(FileManager.default.fileExists(atPath: segment.sentinelURL.path))
        #expect((try? Data(contentsOf: segment.sentinelURL)) == segment.sentinelBytes)
        #expect(uploadRequestCount == 0)
        #expect(listingRequestCount == 2)
        #expect(syncedDays().contains(dayString(for: segment.date)))
        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(100)) {
            await recorder.containsSyncComplete()
        }
        #expect(!(await recorder.containsOffline()))
        #expect(!(await recorder.containsAwaitingTunnel()))
    }

    @Test func duplicateAliasConfirmsWithinServiceAndFreshServiceFailsClosed() async throws {
        resetSyncedDaysCache()
        store.reset()
        let oldDate = oldDateForRetention()

        let aliasRoot = try makeTempDirectory("sync-duplicate-alias")
        let aliasSegment = try makeSegment(root: aliasRoot, date: oldDate)
        let aliasSha = try sha256(of: aliasSegment.url.appendingPathComponent("\(aliasSegment.url.lastPathComponent)_audio.m4a"))
        let storedKey = "120001_300"
        let duplicateBody = #"{"status":"duplicate","existing_segment":{"key":"\#(storedKey)"}}"#
        let heldListing = listingJSON(
            key: storedKey,
            submittedName: "\(aliasSegment.url.lastPathComponent)_audio.m4a",
            sha: aliasSha,
            status: "present"
        )
        let aliasService = makeService(root: aliasRoot, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24686") })
        await configure(aliasService, cacheRetentionDays: 0)

        store.enqueue(statusCode: 200, body: "[]")
        store.enqueue(statusCode: 200, body: duplicateBody)
        await aliasService.sync()
        #expect(FileManager.default.fileExists(atPath: aliasSegment.url.path))

        store.reset()
        store.enqueue(statusCode: 200, body: heldListing)
        store.enqueue(statusCode: 200, body: heldListing)
        await aliasService.sync()
        #expect(!FileManager.default.fileExists(atPath: aliasSegment.url.path))

        resetSyncedDaysCache()
        store.reset()
        let freshRoot = try makeTempDirectory("sync-duplicate-fresh")
        let freshSegment = try makeSegment(root: freshRoot, date: oldDate)
        let freshSha = try sha256(of: freshSegment.url.appendingPathComponent("\(freshSegment.url.lastPathComponent)_audio.m4a"))
        let freshListing = listingJSON(
            key: storedKey,
            submittedName: "\(freshSegment.url.lastPathComponent)_audio.m4a",
            sha: freshSha,
            status: "present"
        )
        let freshService = makeService(root: freshRoot, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24687") })
        await configure(freshService, cacheRetentionDays: 0)
        store.enqueue(statusCode: 200, body: freshListing)
        store.enqueue(statusCode: 200, body: duplicateBody)

        await freshService.sync()

        #expect(FileManager.default.fileExists(atPath: freshSegment.url.path))
        #expect(store.snapshotRequests().filter { $0.url?.path == "/app/devices/ingest" }.count == 1)
    }

    @Test(arguments: [401, 403, 500])
    func dayQueryHTTPFailureYieldsOfflineAndRetainsLocalSegment(statusCode: Int) async throws {
        try await assertDayQueryFailure(
            testName: "sync-day-query-http-\(statusCode)",
            statusCode: statusCode,
            body: #"{"error":"sensitive"}"#,
            expectedHealthReason: .httpStatus(statusCode)
        )
    }

    @Test func dayQueryMalformedBodyYieldsInvalidResponseAndRetainsLocalSegment() async throws {
        try await assertDayQueryFailure(
            testName: "sync-day-query-invalid-response",
            statusCode: 200,
            body: "{}",
            expectedHealthReason: .uploadInvalidResponse
        )
    }

    @Test func emptyServerListingStillCompletesSuccessfulSync() async throws {
        resetSyncedDaysCache()
        store.reset()
        store.enqueue(statusCode: 200, body: "[]")
        store.enqueue(statusCode: 200, body: "{}")
        let root = try makeTempDirectory("sync-empty-listing-success")
        _ = try makeSegment(root: root)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24689") })
        let recorder = SyncProgressRecorder()
        let eventTask = await recordProgress(from: service, into: recorder)
        defer { eventTask.cancel() }
        await configure(service)

        await service.sync()

        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(100)) {
            await recorder.containsSyncComplete()
        }
        #expect(await recorder.journalContactPrecedesSyncComplete())
        #expect(!(await recorder.containsOffline()))
    }

    @Test func retryExhaustionEndsOfflineInsteadOfSyncComplete() async throws {
        resetSyncedDaysCache()
        store.reset()
        store.enqueue(statusCode: 200, body: "[]")
        for _ in 0..<10 {
            store.enqueue(statusCode: 500, body: "temporary")
        }
        let root = try makeTempDirectory("sync-retry-exhaustion")
        _ = try makeSegment(root: root)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24690") },
            retryDelays: Array(repeating: 0, count: 10)
        )
        let recorder = SyncProgressRecorder()
        let eventTask = await recordProgress(from: service, into: recorder)
        defer { eventTask.cancel() }
        await configure(service)

        await service.sync()

        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(100)) {
            await recorder.lastEventIsOffline(healthReason: .httpStatus(500))
        }
        #expect(await recorder.containsUploadFailed())
        #expect(!(await recorder.containsSyncComplete()))
    }

    private func makeService(
        root: URL,
        resolver: HomeBaseURLResolver,
        retryDelays: [TimeInterval] = [5, 30, 120, 300]
    ) -> SyncService {
        SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: resolver,
            retryDelays: retryDelays
        )
    }

    private func configure(
        _ service: SyncService,
        configuredServerURL: String = "https://configured.example",
        serverKey: String = "secret",
        cacheRetentionDays: Int = -1
    ) async {
        await service.configure(
            serverURL: configuredServerURL,
            serverKey: serverKey,
            cacheRetentionDays: cacheRetentionDays,
            syncPaused: false
        )
    }

    private func recordProgress(
        from service: SyncService,
        into recorder: SyncProgressRecorder
    ) async -> Task<Void, Never> {
        let stream = await service.progressStream
        return Task {
            for await event in stream {
                await recorder.record(event)
            }
        }
    }

    private func makeSegment(
        root: URL,
        date: Date = Date(),
        segmentName: String = "120000_300"
    ) throws -> (url: URL, date: Date) {
        let dayDir = root.appendingPathComponent(dateFolderString(for: date), isDirectory: true)
        let segmentURL = dayDir.appendingPathComponent(segmentName, isDirectory: true)
        try FileManager.default.createDirectory(at: segmentURL, withIntermediateDirectories: true)
        let audioURL = segmentURL.appendingPathComponent("\(segmentName)_audio.m4a")
        try Data("audio".utf8).write(to: audioURL)
        return (segmentURL, date)
    }

    private func makeSegmentWithOnlyUploadExcludedFile(
        root: URL,
        date: Date
    ) throws -> (url: URL, date: Date, sentinelURL: URL, sentinelBytes: Data) {
        let segmentName = "120000_300"
        let dayDir = root.appendingPathComponent(dateFolderString(for: date), isDirectory: true)
        let segmentURL = dayDir.appendingPathComponent(segmentName, isDirectory: true)
        try FileManager.default.createDirectory(at: segmentURL, withIntermediateDirectories: true)
        let sentinelURL = segmentURL.appendingPathComponent("\(segmentName)_audio_system.m4a")
        let sentinelBytes = Data("source audio".utf8)
        try sentinelBytes.write(to: sentinelURL)
        return (segmentURL, date, sentinelURL, sentinelBytes)
    }

    private func assertUnprovenListingRetainsAndUploads(
        testName: String,
        listingStatus: String?,
        shaOverride: String?
    ) async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory(testName)
        let segment = try makeSegment(root: root, date: oldDateForRetention())
        let localSha = try sha256(of: segment.url.appendingPathComponent("\(segment.url.lastPathComponent)_audio.m4a"))
        let listing = listingJSON(
            key: segment.url.lastPathComponent,
            submittedName: "\(segment.url.lastPathComponent)_audio.m4a",
            sha: shaOverride ?? localSha,
            status: listingStatus
        )
        store.enqueue(statusCode: 200, body: listing)
        store.enqueue(statusCode: 200, body: "{}")
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24688") })
        await configure(service, cacheRetentionDays: 0)

        await service.sync()

        let requests = store.snapshotRequests()
        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        #expect(requests.filter { $0.url?.path == "/app/devices/ingest" }.count == 1)
        #expect(requests.filter { $0.url?.path.contains("/app/devices/ingest/segments/") == true }.count == 1)
    }

    private func assertDayQueryFailure(
        testName: String,
        statusCode: Int,
        body: String,
        expectedHealthReason: ObserverHealthFailureReason
    ) async throws {
        resetSyncedDaysCache()
        store.reset()
        store.enqueue(statusCode: statusCode, body: body)
        let root = try makeTempDirectory(testName)
        let segment = try makeSegment(root: root, date: oldDateForRetention())
        let day = dayString(for: segment.date)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24691") })
        let recorder = SyncProgressRecorder()
        let eventTask = await recordProgress(from: service, into: recorder)
        defer { eventTask.cancel() }
        await configure(service)

        await service.sync()

        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(100)) {
            await recorder.containsOffline(healthReason: expectedHealthReason)
        }
        #expect(!(await recorder.containsSyncComplete()))
        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        #expect(!syncedDays().contains(day))
    }

    private func oldDateForRetention() -> Date {
        Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
    }

    private func sha256(of fileURL: URL) throws -> String {
        try #require(UploadClient().sha256(of: fileURL))
    }

    private func listingJSON(
        key: String,
        submittedName: String,
        sha: String,
        status: String?
    ) -> String {
        let statusField = status.map { #","status":"\#($0)""# } ?? ""
        return #"[{"key":"\#(key)","files":[{"name":"audio.m4a","size":5,"submitted_name":"\#(submittedName)","sha256":"\#(sha)"\#(statusField)}]}]"#
    }

    private func dateFolderString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func dayString(for date: Date) -> String {
        dateFolderString(for: date).replacingOccurrences(of: "-", with: "")
    }

    private func resetSyncedDaysCache() {
        UserDefaults.standard.removeObject(forKey: "syncedDays")
    }

    private func syncedDays() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "syncedDays"),
              let days = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return days
    }
}

private actor ResolverScript {
    private var values: [ResolvedHomeBase]

    nonisolated var resolver: HomeBaseURLResolver {
        HomeBaseURLResolver {
            await self.next()
        }
    }

    init(_ values: [ResolvedHomeBase]) {
        self.values = values
    }

    func replace(with values: [ResolvedHomeBase]) {
        self.values = values
    }

    private func next() -> ResolvedHomeBase {
        guard !values.isEmpty else {
            return .held
        }
        if values.count == 1 {
            return values[0]
        }
        return values.removeFirst()
    }
}

private actor SyncProgressRecorder {
    private var events: [SyncService.ProgressEvent] = []

    func record(_ event: SyncService.ProgressEvent) {
        events.append(event)
    }

    func containsAwaitingTunnel() -> Bool {
        events.contains { event in
            if case .awaitingTunnel = event {
                return true
            }
            return false
        }
    }

    func containsConfigChangedFailure() -> Bool {
        events.contains { event in
            if case .uploadFailed(_, _, .configChanged) = event {
                return true
            }
            return false
        }
    }

    func containsOffline(healthReason: ObserverHealthFailureReason) -> Bool {
        events.contains { event in
            if case .offline(_, let reason) = event {
                return reason == healthReason
            }
            return false
        }
    }

    func containsOffline() -> Bool {
        events.contains { event in
            if case .offline = event {
                return true
            }
            return false
        }
    }

    func containsSyncComplete() -> Bool {
        events.contains { event in
            if case .syncComplete = event {
                return true
            }
            return false
        }
    }

    func containsUploadFailed() -> Bool {
        events.contains { event in
            if case .uploadFailed = event {
                return true
            }
            return false
        }
    }

    func journalContactPrecedesSyncComplete() -> Bool {
        var sawJournalContact = false
        for event in events {
            if case .journalContactSucceeded = event {
                sawJournalContact = true
            }
            if case .syncComplete = event {
                return sawJournalContact
            }
        }
        return false
    }

    func lastEventIsOffline(healthReason: ObserverHealthFailureReason) -> Bool {
        guard let last = events.last else {
            return false
        }
        if case .offline(_, let reason) = last {
            return reason == healthReason
        }
        return false
    }
}
