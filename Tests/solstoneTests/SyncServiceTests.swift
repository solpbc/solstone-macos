// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import solstone

@Suite("SyncService", .serialized)
struct SyncServiceTests {
    enum ContextStaleness: String, Sendable, CaseIterable {
        case switchToB
        case pairingAFingerprintNil
        case pairingAFingerprintMalformed
        case pairingAFingerprintEqualsB
    }

    enum IncoherentConfigure: String, Sendable, CaseIterable {
        case pairingAFingerprintB
        case pairingAFingerprintNil
        case pairingAFingerprintMalformed
        case nilPairingWithFingerprint
        case bothNil
    }

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

    private func makeHoldingService(root: URL, resolver: HomeBaseURLResolver) -> SyncService {
        SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: holdingURLProtocolConfiguration()),
            resolver: resolver,
            retryDelays: [0]
        )
    }

    private func uploadResponseJSON(
        status: IngestProtocolV3.UploadStatus,
        submitted: String,
        stored: String
    ) -> String {
        switch status {
        case .ok:
            #"{"status":"ok","segment":"\#(submitted)"}"#
        case .collision:
            #"{"status":"collision","segment":"\#(stored)"}"#
        case .duplicate:
            #"{"status":"duplicate","existing_segment":"\#(stored)"}"#
        }
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

    @Test(arguments: ContextStaleness.allCases)
    func postResolveContextChangeFailsClosed(_ variant: ContextStaleness) async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-post-resolve-\(variant)")
        _ = try makeSegment(root: root)
        let resolver = ResolverScript(
            [.url("http://127.0.0.1:24701")],
            parkAfterImmediateCount: 1
        )
        let service = makeService(root: root, resolver: resolver.resolver)
        await configure(service)
        store.enqueue(statusCode: 200, body: manifestJSON())

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        let syncTask = Task { await service.sync() }
        await resolver.waitUntilParked()
        await store.waitForRequestCount(1)
        #expect(store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.manifestPath })
        #expect(store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath } == false)

        await applyStaleness(variant, to: service)
        await resolver.releasePark()
        await syncTask.value
        await collector.waitForConfigChangedFailure()
        listen.cancel()

        #expect(store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath } == false)
        #expect(collector.containsConfigChangedFailure)
        #expect(collector.containsUploadSucceeded == false)
        #expect(await service.storedSegmentAliasCountForTesting == 0)
    }

    @Test(arguments: ContextStaleness.allCases, [IngestProtocolV3.UploadStatus.ok, .collision, .duplicate])
    func postResponseContextChangeFailsClosed(
        _ variant: ContextStaleness,
        _ status: IngestProtocolV3.UploadStatus
    ) async throws {
        resetSyncedDaysCache()
        store.reset()
        SyncServiceHoldingURLProtocol.reset()
        defer { SyncServiceHoldingURLProtocol.releaseHold() }
        let root = try makeTempDirectory("sync-post-response-\(variant)-\(status.rawValue)")
        let segment = try makeSegment(root: root)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        let submitted = "120000_300"
        let storedKey = "120001_300"
        let service = makeHoldingService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24702") }
        )
        await configure(service)

        let holdingStore = SyncServiceHoldingURLProtocol.store
        holdingStore.enqueue(statusCode: 200, body: manifestJSON())
        holdingStore.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: status,
            submitted: submitted,
            stored: storedKey
        ))

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        let syncTask = Task { await service.sync() }
        await holdingStore.waitForRequestCount(2)
        #expect(SyncServiceHoldingURLProtocol.hold.waitUntilWaiting())
        #expect(holdingStore.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath })

        await applyStaleness(variant, to: service)
        SyncServiceHoldingURLProtocol.releaseHold()
        await syncTask.value
        await collector.waitForConfigChangedFailure()
        listen.cancel()

        #expect(collector.containsConfigChangedFailure)
        #expect(collector.containsUploadSucceeded == false)
        #expect(await service.storedSegmentAliasCountForTesting == 0)

        // .ok stores the submitted key, so it never writes an alias; that row
        // is the no-success-event proof above. collision/duplicate isolate the
        // alias cache.
        guard status != .ok else { return }

        guard variant == .switchToB else { return }

        // Keep B active while observing the stale-response effect. Reconfiguring
        // here would clear the alias cache and make this oracle vacuous.
        holdingStore.reset()
        holdingStore.enqueue(statusCode: 200, body: manifestJSON(day: day))
        holdingStore.enqueue(statusCode: 200, body: manifestDayJSON(
            day: day,
            key: storedKey,
            filename: filename,
            sha: sha,
            size: 5
        ))
        holdingStore.enqueue(statusCode: 200, body: segmentsDayJSON(
            key: storedKey,
            filename: filename,
            sha: sha,
            size: 5
        ))
        holdingStore.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: submitted,
            stored: submitted
        ))
        await service.sync()
        #expect(holdingStore.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)

        // A clean B service must make the same absolute decision from the same
        // stored-key-only remote proof.
        holdingStore.reset()
        let cleanRoot = try makeTempDirectory("sync-post-response-clean-b-\(status.rawValue)")
        let cleanSegment = try makeSegment(root: cleanRoot, date: segment.date)
        let cleanFilename = "120000_300_audio.m4a"
        let cleanSHA = try sha256(of: cleanSegment.url.appendingPathComponent(cleanFilename))
        let cleanService = makeHoldingService(
            root: cleanRoot,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24702") }
        )
        await configureB(cleanService)
        holdingStore.enqueue(statusCode: 200, body: manifestJSON(day: day))
        holdingStore.enqueue(statusCode: 200, body: manifestDayJSON(
            day: day,
            key: storedKey,
            filename: cleanFilename,
            sha: cleanSHA,
            size: 5
        ))
        holdingStore.enqueue(statusCode: 200, body: segmentsDayJSON(
            key: storedKey,
            filename: cleanFilename,
            sha: cleanSHA,
            size: 5
        ))
        holdingStore.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: submitted,
            stored: submitted
        ))
        await cleanService.sync()
        #expect(holdingStore.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    @Test(arguments: [IngestProtocolV3.UploadStatus.ok, .collision, .duplicate])
    func coherentUploadYieldsCapturedFingerprint(_ status: IngestProtocolV3.UploadStatus) async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-captured-fingerprint-\(status.rawValue)")
        _ = try makeSegment(root: root)
        store.enqueue(statusCode: 200, body: manifestJSON())
        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: status,
            submitted: "120000_300",
            stored: "120001_300"
        ))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24703") })
        await configure(service)

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForSyncComplete()
        listen.cancel()

        let expected = tunnelJournalConnectionFingerprint(for: pairingA).value
        #expect(collector.uploadSucceededFingerprints == [expected])
        let expectedAliasCount = status == .ok ? 0 : 1
        #expect(await service.storedSegmentAliasCountForTesting == expectedAliasCount)
    }

    @Test(arguments: IncoherentConfigure.allCases)
    func incoherentConfigureMakesNoRequests(_ combo: IncoherentConfigure) async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-incoherent-\(combo)")
        _ = try makeSegment(root: root)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24704") })
        await configureIncoherent(combo, on: service)
        store.enqueue(statusCode: 200, body: manifestJSON())
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForUploadSucceeded(timeout: .milliseconds(25))
        listen.cancel()
        #expect(store.snapshotRequests().isEmpty)
        #expect(collector.containsUploadSucceeded == false)
        #expect(await service.storedSegmentAliasCountForTesting == 0)
    }

    @Test func reconfigureAToBToARestoresUpload() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("sync-a-b-a")
        _ = try makeSegment(root: root)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24705") })
        await configure(service)
        await service.configure(
            pairingIdentity: pairingB,
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB),
            cacheRetentionDays: -1,
            syncPaused: false
        )
        store.enqueue(statusCode: 200, body: manifestJSON())
        store.enqueue(statusCode: 200, body: #"{"status":"ok","segment":"120000_300"}"#)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForUploadSucceeded()
        listen.cancel()
        #expect(collector.uploadSucceededFingerprint == tunnelJournalConnectionFingerprint(for: pairingB).value)

        store.reset()
        await configure(service)
        store.enqueue(statusCode: 200, body: manifestJSON())
        store.enqueue(statusCode: 200, body: #"{"status":"ok","segment":"120000_300"}"#)
        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    private var pairingA: TunnelPairingIdentity {
        TunnelPairingIdentity(instanceID: "instance", fingerprint: "fingerprint")
    }

    private var pairingB: TunnelPairingIdentity {
        TunnelPairingIdentity(instanceID: "other-instance", fingerprint: "other-fingerprint")
    }

    private func configure(_ service: SyncService, cacheRetentionDays: Int = -1) async {
        await service.configure(
            pairingIdentity: pairingA,
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA),
            cacheRetentionDays: cacheRetentionDays,
            syncPaused: false
        )
    }

    private func configureB(_ service: SyncService, cacheRetentionDays: Int = -1) async {
        await service.configure(
            pairingIdentity: pairingB,
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB),
            cacheRetentionDays: cacheRetentionDays,
            syncPaused: false
        )
    }

    private func applyStaleness(_ variant: ContextStaleness, to service: SyncService) async {
        switch variant {
        case .switchToB:
            await service.configure(
                pairingIdentity: pairingB,
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB),
                cacheRetentionDays: -1,
                syncPaused: false
            )
        case .pairingAFingerprintNil:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: nil,
                cacheRetentionDays: -1,
                syncPaused: false
            )
        case .pairingAFingerprintMalformed:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: JournalConnectionFingerprint(value: "not-a-fingerprint"),
                cacheRetentionDays: -1,
                syncPaused: false
            )
        case .pairingAFingerprintEqualsB:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB),
                cacheRetentionDays: -1,
                syncPaused: false
            )
        }
    }

    private func configureIncoherent(_ combo: IncoherentConfigure, on service: SyncService) async {
        switch combo {
        case .pairingAFingerprintB:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB),
                cacheRetentionDays: -1,
                syncPaused: false
            )
        case .pairingAFingerprintNil:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: nil,
                cacheRetentionDays: -1,
                syncPaused: false
            )
        case .pairingAFingerprintMalformed:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: JournalConnectionFingerprint(value: "not-a-fingerprint"),
                cacheRetentionDays: -1,
                syncPaused: false
            )
        case .nilPairingWithFingerprint:
            await service.configure(
                pairingIdentity: nil,
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA),
                cacheRetentionDays: -1,
                syncPaused: false
            )
        case .bothNil:
            await service.configure(
                pairingIdentity: nil,
                journalFingerprint: nil,
                cacheRetentionDays: -1,
                syncPaused: false
            )
        }
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
    private let parkAfterImmediateCount: Int?
    private var immediateRemaining: Int
    private var parkedWaiters: [CheckedContinuation<Void, Never>] = []
    private var parkResume: CheckedContinuation<Void, Never>?
    private var isParked = false

    nonisolated var resolver: HomeBaseURLResolver {
        HomeBaseURLResolver { await self.next() }
    }

    init(_ values: [ResolvedHomeBase], parkAfterImmediateCount: Int? = nil) {
        self.values = values
        self.parkAfterImmediateCount = parkAfterImmediateCount
        self.immediateRemaining = parkAfterImmediateCount ?? 0
    }

    func replace(with values: [ResolvedHomeBase]) { self.values = values }

    func waitUntilParked() async {
        if isParked { return }
        await withCheckedContinuation { parkedWaiters.append($0) }
    }

    func releasePark() {
        isParked = false
        parkResume?.resume()
        parkResume = nil
    }

    private func next() async -> ResolvedHomeBase {
        if parkAfterImmediateCount != nil, immediateRemaining <= 0 {
            isParked = true
            let waiters = parkedWaiters
            parkedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                parkResume = continuation
            }
        } else if parkAfterImmediateCount != nil {
            immediateRemaining -= 1
        }
        guard !values.isEmpty else { return .held }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SyncService.ProgressEvent] = []

    func append(_ event: SyncService.ProgressEvent) {
        lock.withLock { events.append(event) }
    }

    var containsUploadSucceeded: Bool {
        lock.withLock {
            events.contains { if case .uploadSucceeded = $0 { return true }; return false }
        }
    }

    var containsConfigChangedFailure: Bool {
        lock.withLock {
            events.contains {
                if case .uploadFailed(_, _, let reason) = $0, reason == .configChanged {
                    return true
                }
                return false
            }
        }
    }

    var containsSyncComplete: Bool {
        lock.withLock {
            events.contains { if case .syncComplete = $0 { return true }; return false }
        }
    }

    var uploadSucceededFingerprints: [String] {
        lock.withLock {
            events.compactMap { event in
                guard case .uploadSucceeded(_, let fingerprint) = event else {
                    return nil
                }
                return fingerprint
            }
        }
    }

    var uploadSucceededFingerprint: String? {
        uploadSucceededFingerprints.first
    }

    func waitForUploadSucceeded(timeout: Duration = .seconds(10)) async {
        await waitUntil(timeout: timeout) { containsUploadSucceeded }
    }

    func waitForConfigChangedFailure(timeout: Duration = .seconds(10)) async {
        await waitUntil(timeout: timeout) { containsConfigChangedFailure }
    }

    func waitForSyncComplete(timeout: Duration = .seconds(10)) async {
        await waitUntil(timeout: timeout) { containsSyncComplete }
    }

    private func waitUntil(timeout: Duration, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class SyncServiceUploadHoldGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var waiterCount = 0

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilWaiting(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while waiterCount == 0, !released {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        return waiterCount > 0
    }

    func wait() {
        condition.lock()
        waiterCount += 1
        condition.broadcast()
        while !released {
            condition.wait()
        }
        waiterCount -= 1
        condition.unlock()
    }
}

private final class SyncServiceHoldSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = SyncServiceUploadHoldGate()

    var current: SyncServiceUploadHoldGate {
        lock.withLock { gate }
    }

    func rotate() {
        lock.lock()
        let previous = gate
        gate = SyncServiceUploadHoldGate()
        lock.unlock()
        previous.release()
    }
}

private final class SyncServiceHoldingURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = ObserverURLProtocolStore()
    private static let slot = SyncServiceHoldSlot()

    static var hold: SyncServiceUploadHoldGate {
        slot.current
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next = Self.store.next(for: request)
        guard request.url?.path == IngestProtocolV3.uploadPath else {
            Self.deliver(next, from: self)
            return
        }

        let gate = Self.hold
        DispatchQueue.global().async { [self] in
            gate.wait()
            guard gate === Self.hold else { return }
            Self.deliver(next, from: self)
        }
    }

    // URLSession invokes stopLoading before a held POST is released; tests
    // open the gate explicitly so a cancel cannot deliver the response early.
    override func stopLoading() {}

    static func reset() {
        store.reset()
        slot.rotate()
    }

    static func releaseHold() {
        hold.release()
    }

    private static func deliver(_ next: ObserverURLProtocolStore.Response, from urlProtocol: URLProtocol) {
        if let error = next.error {
            urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: urlProtocol.request.url!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !next.data.isEmpty {
            urlProtocol.client?.urlProtocol(urlProtocol, didLoad: next.data)
        }
        urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
    }
}

private func holdingURLProtocolConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SyncServiceHoldingURLProtocol.self]
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 120
    return config
}
