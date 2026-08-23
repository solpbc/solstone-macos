// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import solstone

@Suite("SyncService", .serialized)
struct SyncServiceTests {
    private let store = ObserverURLProtocolStore()

    @Test func heldBeforeServerSegmentsMakesNoRequestAndNextURLProceeds() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-held")
        let segment = try makeSegment(root: root)
        let resolver = ResolverScript([.held])
        let service = makeService(root: root, resolver: resolver.resolver)
        await configure(service)

        await service.sync()
        #expect(store.snapshotRequests().isEmpty)
        #expect(FileManager.default.fileExists(atPath: segment.url.path))

        store.enqueue(statusCode: 200, body: manifestJSON())
        store.enqueue(statusCode: 200, body: #"{"status":"ok","segment":"120000_300"}"#)
        await resolver.replace(with: [.url("http://127.0.0.1:24683")])
        await service.sync()

        let requests = store.snapshotRequests()
        #expect(requests.count == 2)
        #expect(requests.first?.url?.path == IngestProtocolV3.manifestPath)
        #expect(requests.last?.url?.path == IngestProtocolV3.uploadPath)
    }

    @Test func v3ReadsUseManifestThenPerDayProofRoutesWithoutBearer() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-v3-routes")
        let segment = try makeSegment(root: root)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: manifestJSON(day: day))
        store.enqueue(statusCode: 200, body: manifestDayJSON(day: day, key: "120000_300", filename: filename, sha: sha, size: 5))
        store.enqueue(statusCode: 200, body: segmentsDayJSON(key: "120000_300", filename: filename, sha: sha, size: 5))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24682") })
        await configure(service)

        await service.sync()

        let paths = store.snapshotRequests().compactMap { $0.url?.path }
        #expect(paths == [
            IngestProtocolV3.manifestPath,
            IngestProtocolV3.manifestDayPath(day),
            IngestProtocolV3.segmentsDayPath(day),
        ])
        for request in store.snapshotRequests() {
            #expect(request.value(forHTTPHeaderField: IngestProtocolV3.headerName) == IngestProtocolV3.headerValue)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test func perSegmentReadDisagreementUploadsOnlyThatSegment() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-per-segment-disagreement")
        let first = try makeSegment(root: root, segmentName: "120000_300")
        let second = try makeSegment(root: root, segmentName: "120500_300")
        let day = dayString(for: first.date)
        let firstSHA = try sha256(of: first.url.appendingPathComponent("120000_300_audio.m4a"))
        let secondSHA = try sha256(of: second.url.appendingPathComponent("120500_300_audio.m4a"))
        store.enqueue(statusCode: 200, body: manifestJSON(day: day, segments: 2))
        store.enqueue(statusCode: 200, body: manifestDayJSON(
            day: day,
            entries: [
                ("120000_300", "120000_300_audio.m4a", firstSHA, 5, "present"),
                ("120500_300", "120500_300_audio.m4a", secondSHA, 5, "present"),
            ]
        ))
        store.enqueue(statusCode: 200, body: segmentsDayJSON(
            entries: [
                ("120000_300", nil, "120000_300_audio.m4a", firstSHA, 5, "present"),
                ("120500_300", nil, "120500_300_audio.m4a", "different", 5, "present"),
            ]
        ))
        store.enqueue(statusCode: 200, body: #"{"status":"ok","segment":"120500_300"}"#)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24684") })
        await configure(service)

        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    @Test func sizeMismatchRetainsSegmentAndUploads() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-size-mismatch")
        let segment = try makeSegment(root: root)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: manifestJSON(day: day))
        store.enqueue(statusCode: 200, body: manifestDayJSON(day: day, key: "120000_300", filename: filename, sha: sha, size: 4))
        store.enqueue(statusCode: 200, body: segmentsDayJSON(key: "120000_300", filename: filename, sha: sha, size: 4))
        store.enqueue(statusCode: 200, body: #"{"status":"ok","segment":"120000_300"}"#)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24685") })
        await configure(service)

        await service.sync()

        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    @Test func manifestDayErrorFailsClosedBeforeUpload() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-manifest-day-error")
        let segment = try makeSegment(root: root)
        let day = dayString(for: segment.date)
        store.enqueue(statusCode: 200, body: #"{"days":{"\#(day)":{"error":"journal_read_failed"}}}"#)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24686") })
        await configure(service)

        await service.sync()

        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        #expect(store.snapshotRequests().count == 1)
    }

    @Test func duplicateSegmentKeyFailsClosedBeforeReconciliation() async throws {
        let date = try #require(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let root = try makeTempDirectory("sync-duplicate-segment-key")
        let segment = try makeSegment(root: root, date: date)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        let duplicateItems = segmentsDayJSON(entries: [
            ("120000_300", nil, filename, sha, 5, "present"),
            ("120000_300", nil, filename, sha, 5, "present"),
        ])

        try await assertMalformedSegmentsDayFailsClosed(
            root: root,
            segment: segment,
            day: day,
            filename: filename,
            sha: sha,
            malformedSegmentsDay: duplicateItems
        )
    }

    @Test func duplicateEffectiveFilenameFailsClosedBeforeReconciliation() async throws {
        let date = try #require(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let root = try makeTempDirectory("sync-duplicate-effective-filename")
        let segment = try makeSegment(root: root, date: date)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        let file = "{\"name\":\"audio.m4a\",\"submitted_name\":\"\(filename)\",\"sha256\":\"\(sha)\",\"size\":5,\"status\":\"present\"}"
        let duplicateFiles = "{\"protocol_version\":3,\"total\":1,\"items\":[{\"key\":\"120000_300\",\"observed\":true,\"files\":[\(file),\(file)]}]}"

        try await assertMalformedSegmentsDayFailsClosed(
            root: root,
            segment: segment,
            day: day,
            filename: filename,
            sha: sha,
            malformedSegmentsDay: duplicateFiles
        )
    }

    @Test func duplicateOriginalKeyFailsClosedBeforeReconciliation() async throws {
        let date = try #require(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let root = try makeTempDirectory("sync-duplicate-original-key")
        let segment = try makeSegment(root: root, date: date)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        let duplicateItems = segmentsDayJSON(entries: [
            ("120001_300", "120000_300", filename, sha, 5, "present"),
            ("120002_300", "120000_300", filename, sha, 5, "present"),
        ])

        try await assertMalformedSegmentsDayFailsClosed(
            root: root,
            segment: segment,
            day: day,
            filename: filename,
            sha: sha,
            malformedSegmentsDay: duplicateItems
        )
    }

    @Test func originalKeyEqualToCanonicalKeyFailsClosedBeforeReconciliation() async throws {
        let date = try #require(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let root = try makeTempDirectory("sync-original-key-canonical-key")
        let segment = try makeSegment(root: root, date: date)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        let ambiguousItems = segmentsDayJSON(entries: [
            ("120001_300", "120002_300", filename, sha, 5, "present"),
            ("120002_300", nil, filename, sha, 5, "present"),
        ])

        try await assertMalformedSegmentsDayFailsClosed(
            root: root,
            segment: segment,
            day: day,
            filename: filename,
            sha: sha,
            malformedSegmentsDay: ambiguousItems
        )
    }

    @Test func noSelectableFilesBlockDaySyncedMark() async throws {
        resetSyncedDaysCache()
        store.reset()
        let date = try #require(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let root = try makeTempDirectory("sync-no-selectable-files")
        let segment = try makeSegment(root: root, date: date)
        try FileManager.default.removeItem(at: segment.url.appendingPathComponent("120000_300_audio.m4a"))
        let day = dayString(for: segment.date)
        store.enqueue(statusCode: 200, body: manifestJSON(day: day))
        store.enqueue(statusCode: 200, body: manifestDayJSON(
            day: day,
            key: "120000_300",
            filename: "120000_300_audio.m4a",
            sha: "server-sha",
            size: 5
        ))
        store.enqueue(statusCode: 200, body: segmentsDayJSON(
            key: "120000_300",
            filename: "120000_300_audio.m4a",
            sha: "server-sha",
            size: 5
        ))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24690") })
        await configure(service, cacheRetentionDays: 0)

        await service.sync()

        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        #expect(store.snapshotRequests().count == 3)
        #expect(store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath } == false)
        #expect(syncedDays().contains(day) == false)
    }

    @Test func duplicateAliasConfirmsWithinServiceAndFreshServiceFailsClosed() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-duplicate-alias")
        let segment = try makeSegment(root: root)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        let storedKey = "120001_300"
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24687") })
        await configure(service)

        store.enqueue(statusCode: 200, body: manifestJSON())
        store.enqueue(statusCode: 200, body: #"{"status":"duplicate","existing_segment":"\#(storedKey)"}"#)
        await service.sync()

        store.reset()
        store.enqueue(statusCode: 200, body: manifestJSON(day: day))
        store.enqueue(statusCode: 200, body: manifestDayJSON(day: day, key: storedKey, filename: filename, sha: sha, size: 5))
        store.enqueue(statusCode: 200, body: segmentsDayJSON(key: storedKey, filename: filename, sha: sha, size: 5))
        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.isEmpty == true)

        resetSyncedDaysCache()
        store.reset()
        let freshRoot = try makeTempDirectory("sync-duplicate-fresh")
        _ = try makeSegment(root: freshRoot)
        let fresh = makeService(root: freshRoot, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24688") })
        await configure(fresh)
        store.enqueue(statusCode: 200, body: manifestJSON(day: day))
        store.enqueue(statusCode: 200, body: manifestDayJSON(day: day, key: storedKey, filename: filename, sha: sha, size: 5))
        store.enqueue(statusCode: 200, body: segmentsDayJSON(key: storedKey, filename: filename, sha: sha, size: 5))
        store.enqueue(statusCode: 200, body: #"{"status":"duplicate","existing_segment":"\#(storedKey)"}"#)
        await fresh.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    private func makeService(root: URL, resolver: HomeBaseURLResolver) -> SyncService {
        SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: resolver,
            retryDelays: [0]
        )
    }

    private func assertMalformedSegmentsDayFailsClosed(
        root: URL,
        segment: (url: URL, date: Date),
        day: String,
        filename: String,
        sha: String,
        malformedSegmentsDay: String
    ) async throws {
        resetSyncedDaysCache()
        store.reset()
        store.enqueue(statusCode: 200, body: manifestJSON(day: day))
        store.enqueue(statusCode: 200, body: manifestDayJSON(day: day, key: "120000_300", filename: filename, sha: sha, size: 5))
        store.enqueue(statusCode: 200, body: malformedSegmentsDay)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24689") })
        await configure(service, cacheRetentionDays: 0)

        await service.sync()

        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        #expect(store.snapshotRequests().count == 3)
        #expect(store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath } == false)
        #expect(syncedDays().contains(day) == false)

        // A subsequent valid manifest still sees the retained segment as needing upload.
        store.reset()
        store.enqueue(statusCode: 200, body: manifestJSON())
        store.enqueue(statusCode: 200, body: #"{"status":"ok","segment":"120000_300"}"#)
        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        #expect(syncedDays().contains(day) == false)
    }

    private func configure(_ service: SyncService, cacheRetentionDays: Int = -1) async {
        await service.configure(
            pairingIdentity: TunnelPairingIdentity(instanceID: "instance", fingerprint: "fingerprint"),
            journalFingerprint: nil,
            cacheRetentionDays: cacheRetentionDays,
            syncPaused: false
        )
    }

    private func makeSegment(root: URL, date: Date = Date(), segmentName: String = "120000_300") throws -> (url: URL, date: Date) {
        let directory = root
            .appendingPathComponent(dateFolderString(for: date), isDirectory: true)
            .appendingPathComponent(segmentName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("\(segmentName)_audio.m4a"))
        return (directory, date)
    }

    private func manifestJSON(day: String? = nil, segments: Int = 1) -> String {
        guard let day else { return #"{"days":{}}"# }
        return #"{"days":{"\#(day)":{"segments":\#(segments)}}}"#
    }

    private func manifestDayJSON(day: String, key: String, filename: String, sha: String, size: Int) -> String {
        manifestDayJSON(day: day, entries: [(key, filename, sha, size, "present")])
    }

    private func manifestDayJSON(day: String, entries: [(String, String, String, Int, String)]) -> String {
        let segments = entries.map { key, filename, sha, size, status in
            "\"\(key)\":{\"files\":[{\"name\":\"audio.m4a\",\"submitted_name\":\"\(filename)\",\"sha256\":\"\(sha)\",\"size\":\(size),\"status\":\"\(status)\"}]}"
        }.joined(separator: ",")
        return "{\"version\":1,\"day\":\"\(day)\",\"segments\":{\(segments)}}"
    }

    private func segmentsDayJSON(key: String, filename: String, sha: String, size: Int) -> String {
        segmentsDayJSON(entries: [(key, nil, filename, sha, size, "present")])
    }

    private func segmentsDayJSON(entries: [(String, String?, String, String, Int, String)]) -> String {
        let items = entries.map { key, originalKey, filename, sha, size, status in
            let original = originalKey.map { ",\"original_key\":\"\($0)\"" } ?? ""
            return "{\"key\":\"\(key)\",\"observed\":true,\"files\":[{\"name\":\"audio.m4a\",\"submitted_name\":\"\(filename)\",\"sha256\":\"\(sha)\",\"size\":\(size),\"status\":\"\(status)\"}]\(original)}"
        }.joined(separator: ",")
        return "{\"protocol_version\":3,\"total\":\(entries.count),\"items\":[\(items)]}"
    }

    private func sha256(of fileURL: URL) throws -> String {
        try #require(UploadClient().sha256(of: fileURL))
    }

    private func dateFolderString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
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
        HomeBaseURLResolver { await self.next() }
    }

    init(_ values: [ResolvedHomeBase]) { self.values = values }

    func replace(with values: [ResolvedHomeBase]) { self.values = values }

    private func next() -> ResolvedHomeBase {
        guard !values.isEmpty else { return .held }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}
