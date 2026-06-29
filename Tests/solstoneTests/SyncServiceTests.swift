// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SyncService", .serialized)
struct SyncServiceTests {
    @Test func relayResolverRoutesGetAndUploadToLoopbackTarget() async throws {
        resetSyncedDaysCache()
        ObserverURLProtocol.store.reset()
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "[]")
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "{}")
        let root = try makeTempDirectory("sync-relay")
        let segment = try makeSegment(root: root)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24682") }
        )
        await configure(service)

        await service.sync()

        let requests = ObserverURLProtocol.store.snapshotRequests()
        let get = try #require(requests.first)
        let post = try #require(requests.dropFirst().first)
        #expect(get.httpMethod == "GET")
        #expect(get.url?.host == "127.0.0.1")
        #expect(get.url?.port == 24682)
        #expect(get.url?.path == "/app/observer/ingest/segments/\(dayString(for: segment.date))")
        #expect(post.httpMethod == "POST")
        #expect(post.url?.host == "127.0.0.1")
        #expect(post.url?.port == 24682)
        #expect(post.url?.path == "/app/observer/ingest")
    }

    @Test func staticResolverRoutesGetAndUploadToExternalTarget() async throws {
        resetSyncedDaysCache()
        ObserverURLProtocol.store.reset()
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "[]")
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "{}")
        let root = try makeTempDirectory("sync-static")
        let segment = try makeSegment(root: root)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("https://journal.example:9443") }
        )
        await configure(service)

        await service.sync()

        let requests = ObserverURLProtocol.store.snapshotRequests()
        let get = try #require(requests.first)
        let post = try #require(requests.dropFirst().first)
        #expect(get.url?.host == "journal.example")
        #expect(get.url?.port == 9443)
        #expect(get.url?.path == "/app/observer/ingest/segments/\(dayString(for: segment.date))")
        #expect(post.url?.host == "journal.example")
        #expect(post.url?.port == 9443)
        #expect(post.url?.path == "/app/observer/ingest")
    }

    @Test func heldBeforeServerSegmentsMakesNoRequestAndNextURLProceeds() async throws {
        resetSyncedDaysCache()
        ObserverURLProtocol.store.reset()
        let root = try makeTempDirectory("sync-held")
        let segment = try makeSegment(root: root)
        let resolver = ResolverScript([.held])
        let service = makeService(root: root, resolver: resolver.resolver)
        let recorder = SyncProgressRecorder()
        let eventTask = await recordProgress(from: service, into: recorder)
        defer { eventTask.cancel() }
        await configure(service)

        await service.sync()

        #expect(ObserverURLProtocol.store.snapshotRequests().isEmpty)
        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(100)) {
            await recorder.containsAwaitingTunnel()
        }

        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "[]")
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "{}")
        await resolver.replace(with: [.url("http://127.0.0.1:24683")])
        await service.sync()

        let requests = ObserverURLProtocol.store.snapshotRequests()
        #expect(requests.count == 2)
        #expect(requests.last?.url?.path == "/app/observer/ingest")
    }

    @Test func sameJournalPortChangeRetriesAgainstNewLoopbackPort() async throws {
        resetSyncedDaysCache()
        ObserverURLProtocol.store.reset()
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "[]")
        ObserverURLProtocol.store.enqueue(statusCode: 500, body: "temporary")
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "{}")
        let root = try makeTempDirectory("sync-port-change")
        _ = try makeSegment(root: root)
        let resolver = HomeBaseURLResolver {
            let uploads = ObserverURLProtocol.store.snapshotRequests()
                .filter { $0.url?.path == "/app/observer/ingest" }
                .count
            return .url(uploads == 0 ? "http://127.0.0.1:1111" : "http://127.0.0.1:2222")
        }
        let service = makeService(root: root, resolver: resolver, retryDelays: [0])
        await configure(service)

        await service.sync()

        let requests = ObserverURLProtocol.store.snapshotRequests()
        let uploadRequests = requests.filter { $0.url?.path == "/app/observer/ingest" }
        #expect(uploadRequests.count == 2)
        #expect(uploadRequests.first?.url?.port == 1111)
        #expect(uploadRequests.last?.url?.port == 2222)
    }

    @Test func differentJournalIdentityAbortsRetryWithConfigChanged() async throws {
        resetSyncedDaysCache()
        ObserverURLProtocol.store.reset()
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "[]")
        ObserverURLProtocol.store.enqueue(statusCode: 500, body: "temporary")
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
        await ObserverURLProtocol.store.waitForRequestCount(2)
        await configure(service, configuredServerURL: "https://configured-b.example")
        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(100)) {
            await recorder.containsConfigChangedFailure()
        }
        await syncTask.value

        #expect(await recorder.containsConfigChangedFailure())
        #expect(ObserverURLProtocol.store.snapshotRequests().count == 2)
    }

    private func makeService(
        root: URL,
        resolver: HomeBaseURLResolver,
        retryDelays: [TimeInterval] = [5, 30, 120, 300]
    ) -> SyncService {
        SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration()),
            resolver: resolver,
            retryDelays: retryDelays
        )
    }

    private func configure(
        _ service: SyncService,
        configuredServerURL: String = "https://configured.example",
        serverKey: String = "secret"
    ) async {
        await service.configure(
            serverURL: configuredServerURL,
            serverKey: serverKey,
            cacheRetentionDays: -1,
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
}
