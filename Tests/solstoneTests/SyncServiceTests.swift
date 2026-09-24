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

    @Test func successfulUploadDeletesSegmentDirectoryImmediately() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-immediate-delete-clean")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24680") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForSyncComplete()
        listen.cancel()

        #expect(progress.containsUploadSucceeded)
        #expect(progress.containsSyncComplete)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().path))
    }

    @Test func successfulUploadWithKeepersRenamesToFailedAndRemovesOnlyConfirmedMedia() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-immediate-delete-keepers")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let audioFile = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let sha = try sha256(of: audioFile)
        let metaFile = seg.url.appendingPathComponent("120000_300_meta.json")
        try Data("{}".utf8).write(to: metaFile)
        let keeperFile = seg.url.appendingPathComponent("extra.txt")
        try Data("keeper".utf8).write(to: keeperFile)

        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: sha, size: 5))

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24681") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForSyncComplete()
        listen.cancel()

        #expect(progress.containsUploadSucceeded)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        let failedDir = seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed")
        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_300_audio.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_300_meta.json").path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("extra.txt").path))
        let ackFile = failedDir.appendingPathComponent("120000_300_ingest_ack.json")
        #expect(FileManager.default.fileExists(atPath: ackFile.path))
    }

    @Test func segmentRemovedOutcomeDeletesSegmentDirectoryImmediately() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-seg-removed-clean")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"status\":\"failed\",\"error\":\"Ingest request failed\",\"reason_code\":\"segment_removed\"}")

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24682") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForSyncComplete()
        listen.cancel()

        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().path))
    }

    @Test func segmentRemovedWithKeepersRenamesToFailedAndRemovesConfirmedMedia() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-seg-removed-keepers")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let keeperFile = seg.url.appendingPathComponent("keeper.bin")
        try Data("keep".utf8).write(to: keeperFile)
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"status\":\"failed\",\"error\":\"Ingest request failed\",\"reason_code\":\"segment_removed\"}")

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24683") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForSyncComplete()
        listen.cancel()

        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        let failedDir = seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed")
        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_300_audio.m4a").path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("keeper.bin").path))
    }

    @Test func localFinishDeletesSettledRemnantWithoutTunnelCall() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-local-finish-remnant")
        let segDir = root.appendingPathComponent("2026-09-20", isDirectory: true).appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let metaURL = segDir.appendingPathComponent("120000_300_meta.json")
        try Data(#"{"unreadable_audio_sources":{}}"#.utf8).write(to: metaURL)

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: "20260920",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: String(repeating: "a", count: 64), size: 5)],
                meta: ["unreadable_audio_sources": .object([:])]
            )
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .held })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: segDir.path))
    }

    @Test func localFinishWithKeepersRenamesToFailed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-local-finish-keepers")
        let segDir = root.appendingPathComponent("2026-09-20", isDirectory: true).appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let metaURL = segDir.appendingPathComponent("120000_300_meta.json")
        try Data(#"{}"#.utf8).write(to: metaURL)
        let keeperURL = segDir.appendingPathComponent("stray.txt")
        try Data("stray".utf8).write(to: keeperURL)

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: "20260920",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: String(repeating: "a", count: 64), size: 5)],
                meta: [:]
            )
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .held })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: segDir.path))
        let failedDir = segDir.deletingLastPathComponent().appendingPathComponent("120000_300.failed")
        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("stray.txt").path))
    }

    @Test func unacknowledgedMediaWithUnreadableMetadataMarkedUnprovable() async throws {
        store.reset()
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        let root = try makeTempDirectory("sync-unreadable-meta-unprovable")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let metaURL = seg.url.appendingPathComponent("120000_300_meta.json")
        try Data("{invalid json".utf8).write(to: metaURL)

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24684") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForSyncComplete()
        listen.cancel()

        #expect(progress.segmentUnprovableCount == 1)
        #expect(FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func beforeRemovalStepHookFiresBeforeEachDestructiveAction() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-before-removal-hook")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let hookCalls = MutexValue<Int>(0)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24686") },
            beforeRemovalStep: {
                hookCalls.withLock { $0 += 1 }
            }
        )
        await configure(service)
        await service.sync()

        #expect(hookCalls.withLock { $0 } >= 3)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func removalAbortsCleanlyIfContextChangesMidRemoval() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-removal-abort-context")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let serviceHolder = MutexValue<SyncService?>(nil)
        let service = SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24687") },
            retryDelays: Array(repeating: 0, count: 10),
            beforeRemovalStep: {
                if let s = serviceHolder.withLock({ $0 }) {
                    await s.configure(pairingIdentity: nil, journalFingerprint: nil, syncPaused: true)
                }
            }
        )
        serviceHolder.withLock { $0 = service }
        await configure(service)
        await service.sync()

        // Removal stopped on the first seam before unlinking; folder still in place
        #expect(FileManager.default.fileExists(atPath: seg.url.path))
        #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))

        // In a later pass after reconfigure: ack for linked journal finishes locally with no upload
        store.reset()
        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24687") })
        await configure(service2)
        await service2.sync()

        let uploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.count == 0)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func discoveryIgnoresFailedAndIncompleteDirectories() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-discovery-ignore-special")
        let dayDir = root.appendingPathComponent("2026-09-20", isDirectory: true)
        let failedDir = dayDir.appendingPathComponent("120000_300.failed", isDirectory: true)
        let incompleteDir = dayDir.appendingPathComponent("120500_300.incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: failedDir.appendingPathComponent("120000_300_audio.m4a"))
        try Data("audio".utf8).write(to: incompleteDir.appendingPathComponent("120500_300_audio.m4a"))

        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24688") })
        await configure(service)
        await service.sync()

        let uploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.isEmpty)
        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(FileManager.default.fileExists(atPath: incompleteDir.path))
    }

    @Test func heldBeforeServerSegmentsMakesNoRequestAndNextURLProceeds() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-held")
        let segment = try makeSegment(root: root)
        let resolver = ResolverScript([.held])
        let service = makeService(root: root, resolver: resolver.resolver)
        await configure(service)

        await service.sync()
        #expect(store.snapshotRequests().isEmpty)
        #expect(FileManager.default.fileExists(atPath: segment.url.path))

        store.enqueue(statusCode: 200, body: uploadResponseJSON())
        await resolver.replace(with: [.url("http://127.0.0.1:24683")])
        await service.sync()

        let requests = store.snapshotRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == IngestProtocolV3.uploadPath)
    }

    @Test func v3ReadsUseSegmentsDayRouteWithoutBearer() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-v3-routes")
        let today = IngestDayKey.string(from: Date())
        store.enqueue(statusCode: 200, body: segmentsDayJSON(entries: []))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24682") })
        await configure(service)

        await service.sync()

        let paths = store.snapshotRequests().compactMap { $0.url?.path }
        #expect(paths == [
            IngestProtocolV3.segmentsDayPath(today),
        ])
        for request in store.snapshotRequests() {
            #expect(request.value(forHTTPHeaderField: IngestProtocolV3.headerName) == IngestProtocolV3.headerValue)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test func ackSizeMismatchUploadsBeforeRemovingSegment() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-size-mismatch")
        let segment = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        // The ack's size does not match the local file, so it does not confirm it.
        let staleAck = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: segment.date),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 4)],
                meta: [:]
            )
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        try IngestAcknowledgmentStore.write(staleAck, to: ackURL)
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24685") })
        await configure(service)

        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: segment.url.path))
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    @Test func ingestHttp404StampsTheFailedRoutePath() async throws {
        let html = "<html>not found</html>"

        store.reset()
        let root = try makeTempDirectory("sync-404-upload")
        _ = try makeSegment(root: root)
        store.enqueue(statusCode: 404, body: html)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24701") }
        )
        await configure(service)
        let events = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                events.append(event)
            }
        }
        await service.sync()
        await events.waitForOffline()
        listen.cancel()
        #expect(events.offlinePath() == IngestProtocolV3.uploadPath)

        store.reset()
        let idleRoot = try makeTempDirectory("sync-404-probe")
        let today = IngestDayKey.string(from: Date())
        store.enqueue(statusCode: 404, body: html)
        let idleService = makeService(
            root: idleRoot,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24702") }
        )
        await configure(idleService)
        let idleEvents = ProgressCollector()
        let idleListen = Task {
            for await event in await idleService.progressStream {
                idleEvents.append(event)
            }
        }
        await idleService.sync()
        await idleEvents.waitForOffline()
        idleListen.cancel()
        #expect(idleEvents.offlinePath() == IngestProtocolV3.segmentsDayPath(today))
    }

    @Test func noSelectableFilesDoesNotBlockDaySyncedMark() async throws {
        store.reset()
        let date = try #require(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let root = try makeTempDirectory("sync-no-selectable-files")
        let segment = try makeUnuploadableSegment(root: root, date: date, segmentName: "120000_300")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24690") })
        await configure(service)

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }

        await service.sync()
        await collector.waitForSegmentUnprovable()
        listen.cancel()

        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        #expect(store.snapshotRequests().count == 1)
        #expect(store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath } == false)
        #expect(collector.segmentUnprovableCount == 1)
    }

    @Test func poisonSegmentDoesNotStrandProvenSiblingSegments() async throws {
        store.reset()
        let date = try #require(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let root = try makeTempDirectory("sync-poison-sibling")
        let real = try makeSegment(root: root, date: date, segmentName: "110000_300")
        let poison = try makeUnuploadableSegment(root: root, date: date, segmentName: "130000_300")
        let filename = "110000_300_audio.m4a"
        let sha = try sha256(of: real.url.appendingPathComponent(filename))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24691") })
        await configure(service)

        // The real segment uploads and is removed on confirmation; the poison segment
        // is skipped without reaching the network.
        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: "110000_300",
            stored: "110000_300",
            filename: filename,
            sha: sha,
            size: 5
        ))
        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(FileManager.default.fileExists(atPath: real.url.path) == false)
        #expect(FileManager.default.fileExists(atPath: poison.url.path) == true)
    }

    @Test func segmentDirectoryListabilityDistinguishesMissingFromEmpty() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-listability-empty")
        let dayDir = root.appendingPathComponent("2026-09-14", isDirectory: true)
        let emptySegment = dayDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySegment, withIntermediateDirectories: true)
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24740") })
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

        #expect(!FileManager.default.fileExists(atPath: emptySegment.path))
        #expect(FileManager.default.fileExists(atPath: dayDir.path))
        #expect(collector.segmentUnprovableCount == 0)
        #expect(collector.containsSyncComplete == true)
        #expect(collector.containsOffline == false)

        // Contrast: an unlistable segment directory fails discovery, emitting discovery offline, no syncComplete, and making no HTTP requests
        store.reset()
        let rootUnlistable = try makeTempDirectory("sync-listability-unlistable")
        let dayDir2 = rootUnlistable.appendingPathComponent("2026-09-14", isDirectory: true)
        let unlistableSegment = dayDir2.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: unlistableSegment, withIntermediateDirectories: true)

        let serviceUnlistable = makeService(
            root: rootUnlistable,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24740") },
            listDirectory: { url in
                if url.lastPathComponent == unlistableSegment.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }
        )
        await configure(serviceUnlistable)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await serviceUnlistable.progressStream {
                collector2.append(event)
            }
        }
        await serviceUnlistable.sync()
        await collector2.waitForOffline()
        listen2.cancel()

        #expect(store.snapshotRequests().isEmpty)
        #expect(collector2.segmentUnprovableCount == 0)
        #expect(collector2.containsSyncComplete == false)
        #expect(collector2.containsOffline == true)
        #expect(collector2.offlinePath() == "")
    }

    @Test func discoveryBaseDirectoryListFailureFailsClosedWithoutNetwork() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-base-list-fail")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let seg = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let audioFile = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let audioSHA = try sha256(of: audioFile)

        // Pass 1: base directory listing fails
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24741") },
            listDirectory: { url in
                if url.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
                }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().isEmpty)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        let offline = collector.offlineEvents.first
        #expect(offline?.healthReason == .uploadFailed)
        #expect(offline?.requestedPath == "")
        #expect(FileManager.default.fileExists(atPath: audioFile.path) == true)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)

        // Pass 2: recovered default service uploads the segment
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: audioSHA, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24741") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func discoveryDateDirectoryListFailureWithNoDiscoverableSegmentFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-date-list-fail-empty")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let seg = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let dateDir = seg.url.deletingLastPathComponent()
        let audioFile = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let audioSHA = try sha256(of: audioFile)

        // Pass 1: the only date directory throws from listDirectory
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24742") },
            listDirectory: { url in
                if url.lastPathComponent == dateDir.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().isEmpty)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        let offline = collector.offlineEvents.first
        #expect(offline?.healthReason == .uploadFailed)
        #expect(offline?.requestedPath == "")
        #expect(FileManager.default.fileExists(atPath: audioFile.path) == true)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)

        // Pass 2: recovered default service uploads the segment
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: audioSHA, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24742") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func discoverySegmentDirectoryListFailureWithNoSiblingFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-seg-list-fail-empty")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let seg = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let audioFile = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let audioSHA = try sha256(of: audioFile)

        // Pass 1: the only segment directory throws from listDirectory
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24743") },
            listDirectory: { url in
                if url.lastPathComponent == seg.url.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().isEmpty)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        let offline = collector.offlineEvents.first
        #expect(offline?.healthReason == .uploadFailed)
        #expect(offline?.requestedPath == "")
        #expect(FileManager.default.fileExists(atPath: audioFile.path) == true)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)

        // Pass 2: recovered default service uploads the segment
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: audioSHA, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24743") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func discoveryRootChildClassifyErrorWithNoSiblingFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-root-classify-err-empty")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let seg = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let dateDir = seg.url.deletingLastPathComponent()
        let audioFile = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let audioSHA = try sha256(of: audioFile)

        // Pass 1: root child date dir classify throws
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24744") },
            classifyEntry: { url in
                if url.lastPathComponent == dateDir.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let ft = info.st_mode & mode_t(S_IFMT)
                return ft == mode_t(S_IFDIR) ? .directory : (ft == mode_t(S_IFREG) ? .regularFile : .unsupported)
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().isEmpty)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        let offline = collector.offlineEvents.first
        #expect(offline?.healthReason == .uploadFailed)
        #expect(offline?.requestedPath == "")
        #expect(FileManager.default.fileExists(atPath: audioFile.path) == true)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)

        // Pass 2: recovered default service uploads the segment
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: audioSHA, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24744") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func discoveryUploadMediaChildClassifyErrorWithNoSiblingFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-media-classify-err-empty")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let seg = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let audioFile = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let audioSHA = try sha256(of: audioFile)

        // Pass 1: only upload-eligible media child classify throws
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24745") },
            classifyEntry: { url in
                if url.lastPathComponent == audioFile.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let ft = info.st_mode & mode_t(S_IFMT)
                return ft == mode_t(S_IFDIR) ? .directory : (ft == mode_t(S_IFREG) ? .regularFile : .unsupported)
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        let pass1UploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(pass1UploadRequests.isEmpty)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        let offline = collector.offlineEvents.first
        #expect(offline?.healthReason == .uploadFailed)
        #expect(offline?.requestedPath == "")
        #expect(FileManager.default.fileExists(atPath: audioFile.path) == true)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)

        // Pass 2: recovered default service uploads the segment
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: audioSHA, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24745") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func discoveryDateChildClassifyErrorWithNoSiblingFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-date-child-classify-err-empty")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let seg = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let audioFile = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let audioSHA = try sha256(of: audioFile)

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24764") },
            classifyEntry: { url in
                if url.lastPathComponent == seg.url.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let ft = info.st_mode & mode_t(S_IFMT)
                return ft == mode_t(S_IFDIR) ? .directory : (ft == mode_t(S_IFREG) ? .regularFile : .unsupported)
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().isEmpty)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        let offline = collector.offlineEvents.first
        #expect(offline?.healthReason == .uploadFailed)
        #expect(offline?.requestedPath == "")
        #expect(FileManager.default.fileExists(atPath: audioFile.path) == true)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)

        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: audioSHA, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24764") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func discoveryRootChildClassifyErrorRecordsFailureUploadsValidAndFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-root-classify-err")
        let today = Date()
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: today)!
        let validSegment = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let otherDateDir = root.appendingPathComponent("2026-09-10", isDirectory: true)
        let otherSegDir = otherDateDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: otherSegDir, withIntermediateDirectories: true)
        let otherAudio = otherSegDir.appendingPathComponent("120000_300_audio.m4a")
        try Data("other".utf8).write(to: otherAudio)
        let otherSHA = try sha256(of: otherAudio)

        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: validSegment.url.appendingPathComponent(filename))

        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24748") },
            classifyEntry: { url in
                if url.lastPathComponent == otherDateDir.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let ft = info.st_mode & mode_t(S_IFMT)
                return ft == mode_t(S_IFDIR) ? .directory : (ft == mode_t(S_IFREG) ? .regularFile : .unsupported)
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector.containsUploadSucceeded == true)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        #expect(collector.offlinePath() == "")
        #expect(!FileManager.default.fileExists(atPath: validSegment.url.path))
        #expect(FileManager.default.fileExists(atPath: otherAudio.path) == true)

        // Pass 2: default service recovers; sibling not re-posted, other posted once
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: otherSHA, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24748") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(!FileManager.default.fileExists(atPath: otherSegDir.path))
    }

    @Test func discoveryRootChildNonDirectoryIgnored() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-root-non-dir")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let strayFile = root.appendingPathComponent("stray.txt")
        try Data("stray".utf8).write(to: strayFile)

        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24751") })
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

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector.containsSyncComplete == true)
        #expect(collector.containsOffline == false)
    }

    @Test func discoveryDateDirectoryListFailureRecordsFailureAndFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-date-list-fail")
        let validSegment = try makeSegment(root: root, date: Date(), segmentName: "120000_300")
        let failingDateDir = root.appendingPathComponent("2026-09-01", isDirectory: true)
        let failingSegDir = failingDateDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: failingSegDir, withIntermediateDirectories: true)
        let failingAudio = failingSegDir.appendingPathComponent("120000_300_audio.m4a")
        try Data("failing".utf8).write(to: failingAudio)
        let failingSHA = try sha256(of: failingAudio)

        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: validSegment.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24746") },
            listDirectory: { url in
                if url.lastPathComponent == failingDateDir.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        #expect(collector.offlinePath() == "")
        #expect(!FileManager.default.fileExists(atPath: validSegment.url.path))
        #expect(FileManager.default.fileExists(atPath: failingAudio.path) == true)

        // Pass 2: default service recovers; sibling not re-posted, failing segment posted once
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: failingSHA, size: 7))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24746") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(!FileManager.default.fileExists(atPath: failingSegDir.path))
    }

    @Test func discoveryDateChildClassifyErrorRecordsFailureAndFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-date-child-classify-err")
        let seg1 = try makeSegment(root: root, segmentName: "120000_300")
        let seg2 = try makeSegment(root: root, segmentName: "120500_300")

        let filename1 = "120000_300_audio.m4a"
        let sha1 = try sha256(of: seg1.url.appendingPathComponent(filename1))
        let filename2 = "120500_300_audio.m4a"
        let sha2 = try sha256(of: seg2.url.appendingPathComponent(filename2))

        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename1, sha: sha1, size: 5))

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24749") },
            classifyEntry: { url in
                if url.lastPathComponent == seg2.url.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let ft = info.st_mode & mode_t(S_IFMT)
                return ft == mode_t(S_IFDIR) ? .directory : (ft == mode_t(S_IFREG) ? .regularFile : .unsupported)
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        #expect(collector.offlinePath() == "")
        #expect(!FileManager.default.fileExists(atPath: seg1.url.path))
        let seg2Audio = seg2.url.appendingPathComponent(filename2)
        #expect(FileManager.default.fileExists(atPath: seg2Audio.path) == true)

        // Pass 2: default service recovers; seg1 not re-posted, seg2 posted once
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(submitted: "120500_300", stored: "120500_300", filename: filename2, sha: sha2, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24749") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(!FileManager.default.fileExists(atPath: seg2.url.path))
    }

    @Test func discoveryDateChildNonDirectoryIgnored() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-date-child-non-dir")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let dateDir = seg.url.deletingLastPathComponent()
        let strayFile = dateDir.appendingPathComponent("stray.tmp")
        try Data("stray".utf8).write(to: strayFile)

        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24752") })
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

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector.containsSyncComplete == true)
        #expect(collector.containsOffline == false)
    }

    @Test func discoveryIncompleteAndFailedSegmentDirectoriesSkipped() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-skipped-suffixes")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let dateDir = seg.url.deletingLastPathComponent()
        let incompleteDir = dateDir.appendingPathComponent("120500_300.incomplete", isDirectory: true)
        let failedDir = dateDir.appendingPathComponent("121000_300.failed", isDirectory: true)
        try FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)

        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24753") })
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

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector.containsSyncComplete == true)
        #expect(collector.containsOffline == false)
    }

    @Test func discoverySegmentDirectoryListFailureRecordsFailureOmittedFromCandidates() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-segment-list-fail")
        let seg1 = try makeSegment(root: root, segmentName: "120000_300")
        let seg2 = try makeSegment(root: root, segmentName: "120500_300")

        let filename1 = "120000_300_audio.m4a"
        let sha1 = try sha256(of: seg1.url.appendingPathComponent(filename1))
        let filename2 = "120500_300_audio.m4a"
        let sha2 = try sha256(of: seg2.url.appendingPathComponent(filename2))

        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename1, sha: sha1, size: 5))

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24747") },
            listDirectory: { url in
                if url.lastPathComponent == seg2.url.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(collector.segmentUnprovableCount == 0)
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        #expect(collector.offlinePath() == "")
        #expect(!FileManager.default.fileExists(atPath: seg1.url.path))
        let seg2Audio = seg2.url.appendingPathComponent(filename2)
        #expect(FileManager.default.fileExists(atPath: seg2Audio.path) == true)

        // Pass 2: default service recovers; seg1 not re-posted, seg2 posted once
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(submitted: "120500_300", stored: "120500_300", filename: filename2, sha: sha2, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24747") })
        await configure(service2)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector2.containsSyncComplete == true)
        #expect(!FileManager.default.fileExists(atPath: seg2.url.path))
    }

    @Test func discoveryUploadMediaChildClassifyErrorRecordsFailureAndFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-media-classify-err")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let screenURL = seg.url.appendingPathComponent("120000_300_display_1_screen.mp4")
        try Data("screen".utf8).write(to: screenURL)
        let audioURL = seg.url.appendingPathComponent("120000_300_audio.m4a")
        try Data("audio".utf8).write(to: audioURL)

        let screenSHA = try sha256(of: screenURL)
        let audioSHA = try sha256(of: audioURL)
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: "120000_300_display_1_screen.mp4", sha: screenSHA, size: 6))

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24750") },
            classifyEntry: { url in
                if url.lastPathComponent == audioURL.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let ft = info.st_mode & mode_t(S_IFMT)
                return ft == mode_t(S_IFDIR) ? .directory : (ft == mode_t(S_IFREG) ? .regularFile : .unsupported)
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlineEvents.count == 1)
        #expect(collector.offlinePath() == "")
        #expect(FileManager.default.fileExists(atPath: screenURL.path) == true)
        #expect(FileManager.default.fileExists(atPath: audioURL.path) == true)
        #expect(FileManager.default.fileExists(atPath: seg.url.path) == true)
    }

    @Test func discoveryUploadMediaSymlinkTreatedAsUnsupportedAndOmitted() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-media-symlink")
        let dateDir = root.appendingPathComponent("2026-09-14", isDirectory: true)
        let segDir = dateDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let outsideFile = root.appendingPathComponent("outside.mp4")
        try Data("outside".utf8).write(to: outsideFile)
        let symlinkMedia = segDir.appendingPathComponent("120000_300_display_1_screen.mp4")
        try FileManager.default.createSymbolicLink(at: symlinkMedia, withDestinationURL: outsideFile)

        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24755") })
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

        #expect(collector.segmentUnprovableCount == 1)
        #expect(collector.containsSyncComplete == true)
        #expect(collector.containsOffline == false)
    }

    @Test func discoveryNonMediaFilesIgnoredWithoutClassification() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-non-media-filter")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let metaURL = seg.url.appendingPathComponent("120000_300_meta.json")
        try Data("{}".utf8).write(to: metaURL)
        let systemAudioURL = seg.url.appendingPathComponent("120000_300_audio_system.m4a")
        try Data("system".utf8).write(to: systemAudioURL)
        let strayURL = seg.url.appendingPathComponent("stray.txt")
        try Data("stray".utf8).write(to: strayURL)

        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        final class ClassifyCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var classifiedURLs: [URL] = []
            func record(_ url: URL) {
                lock.withLock { classifiedURLs.append(url) }
            }
            var all: [URL] { lock.withLock { classifiedURLs } }
        }
        let counter = ClassifyCounter()

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24754") },
            classifyEntry: { url in
                counter.record(url)
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let ft = info.st_mode & mode_t(S_IFMT)
                return ft == mode_t(S_IFDIR) ? .directory : (ft == mode_t(S_IFREG) ? .regularFile : .unsupported)
            }
        )
        await configure(service)
        let snapshot = await service.discover()

        let classifiedNames = Set(counter.all.map(\.lastPathComponent))
        #expect(classifiedNames.contains("120000_300_audio.m4a") == true)
        #expect(classifiedNames.contains("120000_300_meta.json") == false)
        #expect(classifiedNames.contains("120000_300_audio_system.m4a") == false)
        #expect(classifiedNames.contains("stray.txt") == false)
        #expect(snapshot.candidatesByDay.values.flatMap { $0 }.count == 1)
    }

    @Test func discoveryDateListingFailureRemovesEligibleListedSiblingWhileUnlistedStays() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-date-list-skip-cleanup")
        let pastDate1 = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let pastDate2 = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let day1 = dayString(for: pastDate1)
        let day2 = dayString(for: pastDate2)
        let folder2 = dateFolderString(for: pastDate2)

        let seg1 = try makeSegment(root: root, date: pastDate1, segmentName: "120000_300")
        let audio1 = seg1.url.appendingPathComponent("120000_300_audio.m4a")
        let sha1 = try sha256(of: audio1)

        let seg2 = try makeSegment(root: root, date: pastDate2, segmentName: "120000_300")
        let audio2 = seg2.url.appendingPathComponent("120000_300_audio.m4a")
        let sha2 = try sha256(of: audio2)

        // Write usable acks for both segments
        let ack1 = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day1,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: sha1, size: 5)],
                meta: [:]
            ),
            removedMedia: []
        )
        try IngestAcknowledgmentStore.write(ack1, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg1.url, segment: "120000_300"))

        let ack2 = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day2,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: sha2, size: 5)],
                meta: [:]
            ),
            removedMedia: []
        )
        try IngestAcknowledgmentStore.write(ack2, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg2.url, segment: "120000_300"))

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24756") },
            listDirectory: { url in
                if url.lastPathComponent == folder2 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        // The acked segment on the day that listed is removed in that pass
        #expect(!FileManager.default.fileExists(atPath: seg1.url.path))
        // The day whose listDirectory throws is not entered, so its segment stays
        #expect(FileManager.default.fileExists(atPath: seg2.url.path))
        #expect(FileManager.default.fileExists(atPath: audio2.path))
        #expect(collector.offlineEvents.count == 1)
        #expect(collector.containsSyncComplete == false)
        // Zero client requests, no upload, no GET of either segment day
        #expect(store.snapshotRequests().isEmpty)
    }

    @Test func lateArrivalMediaFileIsolatedFromCurrentSyncPass() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-late-media")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let day = dayString(for: pastDate)
        let seg = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let audioFile = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let audioSHA = try sha256(of: audioFile)

        let screenURL = seg.url.appendingPathComponent("120000_300_display_1_screen.mp4")
        let screenData = Data("late-screen-bytes".utf8)
        let screenTemp = try makeTempDirectory("sync-late-screen-temp").appendingPathComponent("screen.mp4")
        try screenData.write(to: screenTemp)
        let screenSHA = try sha256(of: screenTemp)

        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(
            entries: [
                ("120000_300", nil, "120000_300_audio.m4a", audioSHA, 5, "present"),
                ("120000_300", nil, "120000_300_display_1_screen.mp4", screenSHA, screenData.count, "present"),
            ]
        ))

        store.registerRoute(path: IngestProtocolV3.uploadPath, body: uploadResponseJSON(filename: "120000_300_audio.m4a", sha: audioSHA, size: 5))

        let resolver = ResolverScript([.url("http://127.0.0.1:24758"), .url("http://127.0.0.1:24758")], parkAfterImmediateCount: 0)
        let service = makeService(root: root, resolver: resolver.resolver)
        await configure(service)

        let syncing = Task { await service.sync() }
        await resolver.waitUntilParked()

        // Plant late screen media file while sync is parked after discovery
        try screenData.write(to: screenURL)

        await resolver.releasePark()
        await syncing.value

        // The late screen was not in this pass's upload, so the receipt does not confirm it: nothing is removed.
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(FileManager.default.fileExists(atPath: screenURL.path))
        #expect(FileManager.default.fileExists(atPath: audioFile.path))

        // The next pass uploads the screen with the audio, then removes the segment.
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.uploadPath, body: completeUploadResponseJSON(descriptors: [
            ("120000_300_audio.m4a", "120000_300_audio.m4a", 5, audioSHA, "written"),
            ("120000_300_display_1_screen.mp4", "120000_300_display_1_screen.mp4", UInt64(screenData.count), screenSHA, "written"),
        ]))
        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func lateArrivalSegmentIsolatedFromCurrentSyncPass() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-late-segment")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let day = dayString(for: pastDate)
        let seg1 = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let audio1 = seg1.url.appendingPathComponent("120000_300_audio.m4a")
        let sha1 = try sha256(of: audio1)

        let ack1 = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: sha1, size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ack1, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg1.url, segment: "120000_300"))

        let dateDir = seg1.url.deletingLastPathComponent()
        let seg2Dir = dateDir.appendingPathComponent("120500_300", isDirectory: true)
        let audio2URL = seg2Dir.appendingPathComponent("120500_300_audio.m4a")
        let audio2Data = Data("late-audio".utf8)
        let audio2Temp = try makeTempDirectory("sync-late-audio-temp").appendingPathComponent("audio.m4a")
        try audio2Data.write(to: audio2Temp)
        let sha2 = try sha256(of: audio2Temp)

        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(
            entries: [
                ("120000_300", nil, "120000_300_audio.m4a", sha1, 5, "present"),
                ("120500_300", nil, "120500_300_audio.m4a", sha2, audio2Data.count, "present"),
            ]
        ))

        let resolver = ResolverScript([.url("http://127.0.0.1:24757"), .url("http://127.0.0.1:24757")], parkAfterImmediateCount: 0)
        let service = makeService(root: root, resolver: resolver.resolver)
        await configure(service)

        let syncing = Task { await service.sync() }
        await resolver.waitUntilParked()

        // Plant late segment while sync is parked after discovery
        try FileManager.default.createDirectory(at: seg2Dir, withIntermediateDirectories: true)
        try audio2Data.write(to: audio2URL)
        let ack2 = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: "120500_300",
            storedSegmentKey: "120500_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120500_300_audio.m4a", sha256: sha2, size: UInt64(audio2Data.count))],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ack2, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg2Dir, segment: "120500_300"))

        await resolver.releasePark()
        await syncing.value

        // Pass 1: control media deleted; late segment media remains
        #expect(FileManager.default.fileExists(atPath: audio1.path) == false)
        #expect(FileManager.default.fileExists(atPath: audio2URL.path) == true)

        // Pass 2: subsequent sync discovers and cleans up late segment
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(
            entries: [
                ("120000_300", nil, "120000_300_audio.m4a", sha1, 5, "present"),
                ("120500_300", nil, "120500_300_audio.m4a", sha2, audio2Data.count, "present"),
            ]
        ))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24757") })
        await configure(service2)
        await service2.sync()

        #expect(FileManager.default.fileExists(atPath: audio2URL.path) == false)
    }

    @Test func discoverySymlinksIsolatedAtAllLevels() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-symlink-isolation")
        let realSegment = try makeSegment(root: root, segmentName: "120000_300")
        let dateDir = realSegment.url.deletingLastPathComponent()

        // A date symlink to an in-tree date must not replay the real segment under
        // a second day, and a segment symlink from another real date must not replay
        // it there either.
        let inTreeDateLink = root.appendingPathComponent("1999-01-01")
        try FileManager.default.createSymbolicLink(at: inTreeDateLink, withDestinationURL: dateDir)
        let inTreeAliasDate = root.appendingPathComponent("1999-01-02", isDirectory: true)
        try FileManager.default.createDirectory(at: inTreeAliasDate, withIntermediateDirectories: true)
        let inTreeSegmentLink = inTreeAliasDate.appendingPathComponent("120000_300")
        try FileManager.default.createSymbolicLink(at: inTreeSegmentLink, withDestinationURL: realSegment.url)

        // Root level: symlinked date dir pointing at outside tree with real segment & media
        let outsideDir = try makeTempDirectory("sync-outside-date")
        let outsideSeg = outsideDir.appendingPathComponent("130000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideSeg, withIntermediateDirectories: true)
        try Data("outside-date-media".utf8).write(to: outsideSeg.appendingPathComponent("130000_300_audio.m4a"))
        let symlinkDate = root.appendingPathComponent("2026-09-01")
        try FileManager.default.createSymbolicLink(at: symlinkDate, withDestinationURL: outsideDir)

        // Date level: symlinked segment dir pointing at outside segment dir with real media
        let outsideSegDir = try makeTempDirectory("sync-outside-seg")
        try Data("outside-seg-media".utf8).write(to: outsideSegDir.appendingPathComponent("140000_300_audio.m4a"))
        let symlinkSeg = dateDir.appendingPathComponent("140000_300")
        try FileManager.default.createSymbolicLink(at: symlinkSeg, withDestinationURL: outsideSegDir)

        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: realSegment.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24759") })
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

        let uploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.count == 1)
        let bodies = store.snapshotRequestBodyData().compactMap { $0 }
        let bodyString = String(data: bodies[0], encoding: .utf8) ?? ""
        #expect(bodyString.contains("120000_300_audio.m4a") == true)
        #expect(bodyString.contains("130000_300_audio.m4a") == false)
        #expect(bodyString.contains("140000_300_audio.m4a") == false)
        #expect(collector.containsSyncComplete == true)
        #expect(collector.containsOffline == false)
    }

    @Test func outsideRootDateDirectorySymlinkIsNotCleanedWhenInTreeControlIs() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-symlink-cleanup-date")
        let outsideRoot = try makeTempDirectory("sync-symlink-cleanup-outside-date")

        let pastDate1 = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let pastDate2 = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let day1 = dayString(for: pastDate1)
        let day2 = dayString(for: pastDate2)
        let folder2 = dateFolderString(for: pastDate2)

        // In-tree real CONTROL segment
        let controlSeg = try makeSegment(root: root, date: pastDate1, segmentName: "120000_300")
        let controlAudio = controlSeg.url.appendingPathComponent("120000_300_audio.m4a")
        let controlSHA = try sha256(of: controlAudio)
        let controlAck = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day1,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: controlSHA, size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(controlAck, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: controlSeg.url, segment: "120000_300"))

        // Outside tree with date folder2 and segment
        let outsideDateDir = outsideRoot.appendingPathComponent(folder2, isDirectory: true)
        let outsideSegDir = outsideDateDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideSegDir, withIntermediateDirectories: true)
        let outsideAudio = outsideSegDir.appendingPathComponent("120000_300_audio.m4a")
        let outsideBytes = Data("outside-media-bytes".utf8)
        try outsideBytes.write(to: outsideAudio)
        let outsideSHA = try sha256(of: outsideAudio)
        let outsideAck = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day2,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: outsideSHA, size: UInt64(outsideBytes.count))],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(outsideAck, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: outsideSegDir, segment: "120000_300"))

        // In-tree symlink pointing at outside date dir
        let symlinkDate = root.appendingPathComponent(folder2)
        try FileManager.default.createSymbolicLink(at: symlinkDate, withDestinationURL: outsideDateDir)

        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day1), body: segmentsDayJSON(key: "120000_300", filename: "120000_300_audio.m4a", sha: controlSHA, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24760") })
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

        #expect(FileManager.default.fileExists(atPath: controlAudio.path) == false)
        #expect(FileManager.default.fileExists(atPath: outsideAudio.path) == true)
        let actualDateBytes = try Data(contentsOf: outsideAudio)
        #expect(actualDateBytes == outsideBytes)
        let uploadRequestsDate = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequestsDate.isEmpty)
        #expect(collector.containsSyncComplete == true)
    }

    @Test func outsideRootSegmentDirectorySymlinkIsNotCleanedWhenInTreeControlIs() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-symlink-cleanup-seg")
        let outsideRoot = try makeTempDirectory("sync-symlink-cleanup-outside-seg")

        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let day = dayString(for: pastDate)

        // In-tree real date dir and CONTROL segment
        let controlSeg = try makeSegment(root: root, date: pastDate, segmentName: "120000_300")
        let controlAudio = controlSeg.url.appendingPathComponent("120000_300_audio.m4a")
        let controlSHA = try sha256(of: controlAudio)
        let controlAck = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: controlSHA, size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(controlAck, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: controlSeg.url, segment: "120000_300"))

        // Outside segment dir
        let outsideSegDir = outsideRoot.appendingPathComponent("120500_300", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideSegDir, withIntermediateDirectories: true)
        let outsideAudio = outsideSegDir.appendingPathComponent("120500_300_audio.m4a")
        let outsideBytes = Data("outside-seg-bytes".utf8)
        try outsideBytes.write(to: outsideAudio)
        let outsideSHA = try sha256(of: outsideAudio)
        let outsideAck = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: "120500_300",
            storedSegmentKey: "120500_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120500_300_audio.m4a", sha256: outsideSHA, size: UInt64(outsideBytes.count))],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(outsideAck, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: outsideSegDir, segment: "120500_300"))

        // In-tree symlink inside date dir pointing at outside segment dir
        let dateDir = controlSeg.url.deletingLastPathComponent()
        let symlinkSeg = dateDir.appendingPathComponent("120500_300")
        try FileManager.default.createSymbolicLink(at: symlinkSeg, withDestinationURL: outsideSegDir)

        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(key: "120000_300", filename: controlAudio.lastPathComponent, sha: controlSHA, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24761") })
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

        #expect(FileManager.default.fileExists(atPath: controlAudio.path) == false)
        #expect(FileManager.default.fileExists(atPath: outsideAudio.path) == true)
        let actualSegBytes = try Data(contentsOf: outsideAudio)
        #expect(actualSegBytes == outsideBytes)
        let uploadRequestsSeg = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequestsSeg.isEmpty)
        #expect(collector.containsSyncComplete == true)
    }

    @Test func discoveryFailureAndUploadFailureYieldsSingleDiscoveryOffline() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-disc-upload-fail")
        let seg1 = try makeSegment(root: root, segmentName: "120000_300")
        let dateDir = seg1.url.deletingLastPathComponent()
        let failingSeg = dateDir.appendingPathComponent("120500_300", isDirectory: true)
        try FileManager.default.createDirectory(at: failingSeg, withIntermediateDirectories: true)

        let filename1 = "120000_300_audio.m4a"
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.enqueue(statusCode: 500, body: #"{"error":"internal"}"#)

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24762") },
            listDirectory: { url in
                if url.lastPathComponent == failingSeg.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(collector.containsUploadFailed == true)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.offlineEvents.count == 1)
        let offline = collector.offlineEvents.first
        #expect(offline?.requestedPath == "")
        #expect(offline?.healthReason == .uploadFailed)
        #expect(FileManager.default.fileExists(atPath: seg1.url.appendingPathComponent(filename1).path) == true)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg1.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
    }

    @Test func unprovableSegmentWithDiscoveryFailureEmitsUnprovableAndDiscoveryOffline() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-unprovable-disc-fail")
        let dateDir = root.appendingPathComponent("2026-09-14", isDirectory: true)
        let emptySeg = dateDir.appendingPathComponent("120000_300", isDirectory: true)
        let failingSeg = dateDir.appendingPathComponent("120500_300", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySeg, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: emptySeg.appendingPathComponent("120000_300_meta.json"))
        try FileManager.default.createDirectory(at: failingSeg, withIntermediateDirectories: true)

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24763") },
            listDirectory: { url in
                if url.lastPathComponent == failingSeg.lastPathComponent {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }
        )
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(collector.segmentUnprovableCount == 1)
        #expect(collector.containsSyncComplete == false)
        #expect(collector.containsOffline == true)
        #expect(collector.offlinePath() == "")
    }

    @Test func duplicateAliasConfirmsWithinServiceAndFreshServiceFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-duplicate-alias")
        let segment = try makeSegment(root: root)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        let storedKey = "120001_300"
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24687") })
        await configure(service)

        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .duplicate,
            submitted: "120000_300",
            stored: storedKey,
            filename: filename,
            sha: sha,
            size: 5
        ))
        await service.sync()

        // Same directory with saved sidecar receipt skips upload
        store.reset()
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(key: storedKey, filename: filename, sha: sha, size: 5))
        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.isEmpty == true)

        store.reset()
        let freshRoot = try makeTempDirectory("sync-duplicate-fresh")
        _ = try makeSegment(root: freshRoot)
        let fresh = makeService(root: freshRoot, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24688") })
        await configure(fresh)
        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .duplicate,
            submitted: "120000_300",
            stored: storedKey,
            filename: filename,
            sha: sha,
            size: 5
        ))
        await fresh.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    @Test func triggerDuringInFlightPassRunsOneFollowUpPass() async throws {
        store.reset()
        SyncServiceHoldingURLProtocol.reset()
        defer { SyncServiceHoldingURLProtocol.releaseHold() }
        let root = try makeTempDirectory("sync-follow-up")
        _ = try makeSegment(root: root)
        let service = makeHoldingService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24711") }
        )
        await configure(service)

        let holdingStore = SyncServiceHoldingURLProtocol.store
        holdingStore.enqueue(statusCode: 200, body: uploadResponseJSON())
        let today = IngestDayKey.string(from: Date())
        holdingStore.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream { collector.append(event) }
        }
        defer { listen.cancel() }
        let firstPass = Task { await service.sync() }
        await holdingStore.waitForRequestCount(1)
        #expect(SyncServiceHoldingURLProtocol.hold.waitUntilWaiting())

        // Arrives while the upload is still in flight.
        await service.triggerSync()

        SyncServiceHoldingURLProtocol.releaseHold()
        await firstPass.value

        await holdingStore.waitForRequestCount(2, timeout: .seconds(5))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while collector.allEvents.filter({ if case .syncComplete = $0 { return true }; return false }).count < 2,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(collector.allEvents.filter({ if case .syncComplete = $0 { return true }; return false }).count == 2)
        let uploadRequests = holdingStore.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.count == 1)
    }

    @Test func passWithoutMidFlightTriggerRunsNoFollowUp() async throws {
        store.reset()
        SyncServiceHoldingURLProtocol.reset()
        defer { SyncServiceHoldingURLProtocol.releaseHold() }
        let root = try makeTempDirectory("sync-no-follow-up")
        _ = try makeSegment(root: root)
        let service = makeHoldingService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24712") }
        )
        await configure(service)

        let holdingStore = SyncServiceHoldingURLProtocol.store
        holdingStore.enqueue(statusCode: 200, body: uploadResponseJSON())

        let firstPass = Task { await service.sync() }
        await holdingStore.waitForRequestCount(1)
        #expect(SyncServiceHoldingURLProtocol.hold.waitUntilWaiting())
        SyncServiceHoldingURLProtocol.releaseHold()
        await firstPass.value

        // Longer than the trigger debounce, so a spurious follow-up would have shown up.
        try await Task.sleep(for: .milliseconds(1_200))
        let uploadRequests = holdingStore.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.count == 1)
    }

    @Test(arguments: ContextStaleness.allCases)
    func postResolveContextChangeFailsClosed(_ variant: ContextStaleness) async throws {
        store.reset()
        let root = try makeTempDirectory("sync-post-resolve-\(variant)")
        _ = try makeSegment(root: root)
        let resolver = ResolverScript(
            [.url("http://127.0.0.1:24701")],
            parkAfterImmediateCount: 0
        )
        let service = makeService(root: root, resolver: resolver.resolver)
        await configure(service)

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        let syncTask = Task { await service.sync() }
        await resolver.waitUntilParked()
        #expect(store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath } == false)

        await applyStaleness(variant, to: service)
        await resolver.releasePark()
        await syncTask.value
        await collector.waitForConfigChangedFailure()
        listen.cancel()

        #expect(store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath } == false)
        #expect(collector.containsConfigChangedFailure)
        #expect(collector.containsUploadSucceeded == false)
    }

    @Test(arguments: ContextStaleness.allCases, [IngestProtocolV3.UploadStatus.ok, .collision, .duplicate])
    func postResponseContextChangeFailsClosed(
        _ variant: ContextStaleness,
        _ status: IngestProtocolV3.UploadStatus
    ) async throws {
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
        holdingStore.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: status,
            submitted: submitted,
            stored: storedKey,
            filename: filename,
            sha: sha,
            size: 5
        ))

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        let syncTask = Task { await service.sync() }
        await holdingStore.waitForRequestCount(1)
        #expect(SyncServiceHoldingURLProtocol.hold.waitUntilWaiting())
        #expect(holdingStore.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath })

        await applyStaleness(variant, to: service)
        SyncServiceHoldingURLProtocol.releaseHold()
        await syncTask.value
        await collector.waitForConfigChangedFailure()
        listen.cancel()

        #expect(collector.containsConfigChangedFailure)
        #expect(collector.containsUploadSucceeded == false)

        guard status != .ok else { return }
        guard variant == .switchToB else { return }

        holdingStore.reset()
        let today = IngestDayKey.string(from: Date())
        holdingStore.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        holdingStore.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: submitted,
            stored: submitted,
            filename: filename,
            sha: sha,
            size: 5
        ))
        await service.sync()
        #expect(holdingStore.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    @Test(arguments: [IngestProtocolV3.UploadStatus.ok, .collision, .duplicate])
    func coherentUploadYieldsCapturedFingerprint(_ status: IngestProtocolV3.UploadStatus) async throws {
        store.reset()
        let root = try makeTempDirectory("sync-captured-fingerprint-\(status.rawValue)")
        let segment = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: status,
            submitted: "120000_300",
            stored: status == .ok ? "120000_300" : "120001_300",
            filename: filename,
            sha: sha,
            size: 5
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
    }

    @Test(arguments: IncoherentConfigure.allCases)
    func incoherentConfigureMakesNoRequests(_ combo: IncoherentConfigure) async throws {
        store.reset()
        let root = try makeTempDirectory("sync-incoherent-\(combo)")
        _ = try makeSegment(root: root)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24704") })
        await configureIncoherent(combo, on: service)
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
    }

    @Test func reconfigureAToBToARestoresUpload() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-a-b-a")
        let segment = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24605") })
        await configure(service)
        await service.configure(
            pairingIdentity: pairingB,
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB),
            syncPaused: false
        )
        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: "120000_300",
            stored: "120000_300",
            filename: filename,
            sha: sha,
            size: 5
        ))
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
        let seg2 = try makeSegment(root: root, segmentName: "130000_300")
        let filename2 = "130000_300_audio.m4a"
        let sha2 = try sha256(of: seg2.url.appendingPathComponent(filename2))
        await configure(service)
        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: "130000_300",
            stored: "130000_300",
            filename: filename2,
            sha: sha2,
            size: 5
        ))
        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    // MARK: - Journal-rejected day and the per-pass attempt cap

    // MARK: - Attempt cap

    @Test func aSegmentThatKeepsFailingYieldsToTheRestOfThePassAfterThreeAttempts() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-attempt-cap")
        let date = Date()
        // Walked newest key first, so the failing segment is in front of the good one.
        _ = try makeSegment(root: root, date: date, segmentName: "120000_300")
        let small = try makeSegment(root: root, date: date, segmentName: "110000_300")
        let smallSHA = try sha256(of: small.url.appendingPathComponent("110000_300_audio.m4a"))

        // The link drops the first segment's body three times running.
        for _ in 0..<3 {
            store.enqueue(statusCode: 0, error: URLError(.networkConnectionLost))
        }
        let today = IngestDayKey.string(from: date)
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: "110000_300",
            stored: "110000_300",
            filename: "110000_300_audio.m4a",
            sha: smallSHA,
            size: 5
        ))

        let service = SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24693") },
            retryDelays: [0, 0, 0]
        )
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

        // Three attempts on the failing segment, then the pass moved on and the next segment
        // landed: four uploads in one pass, not ten attempts on the first.
        let uploads = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploads.count == 4)
        #expect(collector.containsUploadFailed)
        #expect(collector.containsUploadSucceeded)
        #expect(collector.containsSyncComplete)
        #expect(!collector.containsOffline)
    }

    @Test func aSegmentThatKeepsFailingLivenessURLErrorEndsOffline() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-attempt-cap-liveness-fail")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let pastDay = dayString(for: pastDate)
        _ = try makeSegment(root: root, date: pastDate, segmentName: "100000_300")
        let date = Date()
        _ = try makeSegment(root: root, date: date, segmentName: "120000_300")
        _ = try makeSegment(root: root, date: date, segmentName: "110000_300")

        // First segment fails 3 times with URLError
        for _ in 0..<3 {
            store.enqueue(statusCode: 0, error: URLError(.networkConnectionLost))
        }
        let today = IngestDayKey.string(from: date)
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), statusCode: 0, error: URLError(.networkConnectionLost))

        let service = SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24693") },
            retryDelays: [0, 0, 0]
        )
        await configure(service)

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        let requests = store.snapshotRequests()
        let uploads = requests.filter { $0.url?.path == IngestProtocolV3.uploadPath }
        let pastDayRequests = requests.filter { $0.url?.path == IngestProtocolV3.segmentsDayPath(pastDay) }
        #expect(uploads.count == 3)
        #expect(collector.containsOffline)
        #expect(pastDayRequests.isEmpty)
    }

    // MARK: - New Ingest Acknowledgment and Persistence Tests

    @Test func atomicAcknowledgmentPersistenceFailureFailsUploadAndRetries() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-ack-persist-fail")
        let segment = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))

        // Enqueue 10 upload responses for maxRetries
        for _ in 0..<10 {
            store.enqueue(statusCode: 200, body: uploadResponseJSON(
                status: .ok,
                submitted: "120000_300",
                stored: "120000_300",
                filename: filename,
                sha: sha,
                size: 5
            ))
        }

        struct PersistenceError: Error, LocalizedError {
            var errorDescription: String? { "disk full" }
        }

        let service = SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24606") },
            retryDelays: Array(repeating: 0, count: 10),
            persistAcknowledgment: { _, _ in
                throw PersistenceError()
            }
        )
        await configure(service)

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }

        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(collector.containsUploadSucceeded == false)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: segment.url.appendingPathComponent(filename).path))

        // Next pass, with the ack persisting: the segment uploads again and is removed.
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))
        let next = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24606") })
        await configure(next)
        await next.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: segment.url.path))
    }

    @Test func idempotencyWithAcknowledgedReceiptsSkipsUpload() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-ack-idempotent")
        let segment = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let fileURL = segment.url.appendingPathComponent(filename)
        let sha = try sha256(of: fileURL)
        let stat = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = stat[.size] as? Int64 ?? 5

        let day = dayString(for: segment.date)
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [
                    IngestAcknowledgedFileProof(
                        submitted: filename,
                        sha256: sha,
                        size: UInt64(size)
                    )
                ],
                meta: [:]
            ),
            removedMedia: []
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24607") })
        await configure(service)

        // Sync performs local finish on matching ack: removes segment without upload
        await service.sync()
        let uploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.count == 0)
        #expect(!FileManager.default.fileExists(atPath: segment.url.path))
    }

    @Test func successorAcknowledgmentPreservesRemovedMedia() throws {
        let tempDir = try makeTempDirectory("sync-successor-preserves-removed")
        let screenFile = tempDir.appendingPathComponent("120000_300_display_1_screen.mp4")
        try Data("screen".utf8).write(to: screenFile)

        let prevAck = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: "20260914",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: "sha-audio", size: 5)],
                meta: [:]
            ),
            removedMedia: []
        )

        let newPayload = IngestAcknowledgmentPayload(
            files: [IngestAcknowledgedFileProof(submitted: "120000_300_display_1_screen.mp4", sha256: "sha-screen", size: 6)],
            meta: [:]
        )

        let successor = IngestAcknowledgment.successor(
            previous: prevAck,
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: "20260914",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            newPayload: newPayload,
            segmentDirectory: tempDir,
            sha256Calculator: { _ in nil }
        )

        #expect(successor.payload.files.count == 1)
        #expect(successor.payload.files.first?.submitted == "120000_300_display_1_screen.mp4")
        #expect(successor.removedMedia.count == 1)
        #expect(successor.removedMedia.first?.submitted == "120000_300_audio.m4a")
    }

    @Test func journalFingerprintMismatchForcesReupload() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-fingerprint-mismatch")
        let segment = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))

        let ackA = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: segment.date),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)],
                meta: [:]
            )
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ackA, to: ackURL)

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24609") })
        await configureB(service) // Journal B

        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: "120000_300",
            stored: "120000_300",
            filename: filename,
            sha: sha,
            size: 5
        ))

        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(FileManager.default.fileExists(atPath: segment.url.path) == false)
    }

    @Test func partialCleanupRetryWithThrownRemoveItemRetainsFailedFilesAndRetries() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-partial-cleanup-throw")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let day = dayString(for: pastDate)
        let dateFolder = dateFolderString(for: pastDate)
        let dateDir = root.appendingPathComponent(dateFolder, isDirectory: true)
        let segmentDir = dateDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)

        let screenURL = segmentDir.appendingPathComponent("120000_300_display_1_screen.mp4")
        let audioURL = segmentDir.appendingPathComponent("120000_300_audio.m4a")
        try Data("screen-bytes".utf8).write(to: screenURL)
        try Data("audio-bytes".utf8).write(to: audioURL)
        let screenSHA = try sha256(of: screenURL)
        let audioSHA = try sha256(of: audioURL)

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [
                    IngestAcknowledgedFileProof(submitted: "120000_300_display_1_screen.mp4", sha256: screenSHA, size: 12),
                    IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: audioSHA, size: 11),
                ],
                meta: [:]
            ),
            removedMedia: []
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentDir, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        struct PermissionDeniedError: Error {}
        let didThrow = MutexValue<Bool>(false)

        // Pass 1: removeItem throws on the first call, whatever the name
        let service1 = SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24610") },
            retryDelays: Array(repeating: 0, count: 10),
            removeItem: { url in
                let alreadyThrew = didThrow.withLock { thrown -> Bool in
                    if !thrown {
                        thrown = true
                        return false
                    }
                    return true
                }
                if !alreadyThrew {
                    throw PermissionDeniedError()
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        await configure(service1)
        await service1.sync()

        // Assert the ack is still in the original folder and there was no upload
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == true)
        let pass1UploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(pass1UploadRequests.isEmpty)

        // Pass 2: next service, with a working removeItem, removes the folder and does not upload
        store.reset()
        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24610") })
        await configure(service2)
        await service2.sync()

        #expect(!FileManager.default.fileExists(atPath: segmentDir.path))
        let pass2UploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(pass2UploadRequests.isEmpty)
    }

    @Test func remnantWithChangedMetaAndNoMediaRemovesFolderWithoutUnprovable() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-changed-meta-remnant")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let day = dayString(for: pastDate)
        let dateFolder = dateFolderString(for: pastDate)
        let dateDir = root.appendingPathComponent(dateFolder, isDirectory: true)
        let segmentDir = dateDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)

        let metaURL = segmentDir.appendingPathComponent("120000_300_meta.json")
        try Data(#"{"key":"changed"}"#.utf8).write(to: metaURL)

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [
                    IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: String(repeating: "a", count: 64), size: 10)
                ],
                meta: ["key": .string("value")]
            ),
            removedMedia: []
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentDir, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .held })
        await configure(service)

        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }

        await service.sync()
        listen.cancel()

        #expect(!FileManager.default.fileExists(atPath: segmentDir.path))
        #expect(collector.segmentUnprovableCount == 0)
        #expect(store.snapshotRequests().isEmpty)
    }

    @Test func unreadableMetadataMarksSegmentUnprovableAndSkipsUpload() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-unreadable-meta")
        let segment = try makeSegment(root: root)
        let metaURL = segment.url.appendingPathComponent("120000_300_meta.json")
        try Data("invalid-json{".utf8).write(to: metaURL)
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24612") })
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

        #expect(collector.allEvents.contains {
            if case .segmentUnprovable(let s) = $0, s == "120000_300" { return true }
            return false
        } == true)
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 0)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
    }

    @Test func crossJournalSuccessorDoesNotInheritRemovedMedia() throws {
        let tempDir = try makeTempDirectory("successor-cross-journal")
        let prevAck = IngestAcknowledgment(
            journalFingerprint: "fingerprint-A",
            day: "20260914",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "old_audio.m4a", sha256: "sha1", size: 10)],
                meta: [:]
            ),
            removedMedia: [IngestAcknowledgedFileProof(submitted: "prior_audio.m4a", sha256: "sha0", size: 10)]
        )

        let newPayload = IngestAcknowledgmentPayload(
            files: [IngestAcknowledgedFileProof(submitted: "new_screen.mp4", sha256: "sha2", size: 20)],
            meta: [:]
        )

        // Successor for different journal (fingerprint-B) -> removedMedia is empty
        let successorDifferent = IngestAcknowledgment.successor(
            previous: prevAck,
            journalFingerprint: "fingerprint-B",
            day: "20260914",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            newPayload: newPayload,
            segmentDirectory: tempDir,
            sha256Calculator: { _ in nil }
        )
        #expect(successorDifferent.removedMedia.isEmpty)

        // Successor for same journal (fingerprint-A) -> removedMedia inherits prior_audio and old_audio (since old_audio is not on disk)
        let successorSame = IngestAcknowledgment.successor(
            previous: prevAck,
            journalFingerprint: "fingerprint-A",
            day: "20260914",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            newPayload: newPayload,
            segmentDirectory: tempDir,
            sha256Calculator: { _ in nil }
        )
        #expect(successorSame.removedMedia.count == 2)
        #expect(successorSame.removedMedia.map(\.submitted) == ["old_audio.m4a", "prior_audio.m4a"])
    }

    // MARK: - Helpers

    @Test(arguments: [false, true])
    func failedMetadataUpdateRetainsPreviouslyAcknowledgedMedia(malformed: Bool) async throws {
        store.reset()
        let root = try makeTempDirectory("sync-changed-meta")
        let segment = try makeSegment(root: root, date: Date().addingTimeInterval(-172800))
        let day = dayString(for: segment.date)
        let file = segment.url.appendingPathComponent("120000_300_audio.m4a")
        let sha = try sha256(of: file)
        let receipt = IngestAcknowledgment(journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day, submittedSegment: "120000_300", storedSegmentKey: "120000_300", status: .ok,
            payload: .init(files: [.init(submitted: file.lastPathComponent, sha256: sha, size: 5)], meta: [:]))
        let receiptURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        try IngestAcknowledgmentStore.write(receipt, to: receiptURL)
        try Data((malformed ? "{" : #"{"updated":true}"#).utf8).write(to: segment.url.appendingPathComponent("120000_300_meta.json"))
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24731") })
        await configure(service)
        await service.sync()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: segment.url.path))
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.isEmpty == true)
    }

    @Test func duplicateUploadRemovesConfirmedSegment() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-duplicate-written-name")
        let segment = try makeSegment(root: root, date: Date().addingTimeInterval(-172800))
        let file = segment.url.appendingPathComponent("120000_300_audio.m4a")
        store.enqueue(body: uploadResponseJSON(status: .duplicate, stored: "115959_300"))
        let first = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24732") })
        await configure(first)
        await first.sync()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: segment.url.path))
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    @Test(arguments: [false, true])
    func retryReplaysStagedBytesAfterPartialFailureOrLostReply(lostReply: Bool) async throws {
        store.reset()
        let root = try makeTempDirectory("sync-stable-retry")
        let segment = try makeSegment(root: root)
        let file = segment.url.appendingPathComponent("120000_300_audio.m4a")
        store.enqueue(statusCode: 500, error: lostReply ? URLError(.networkConnectionLost) : nil)
        store.enqueue(body: uploadResponseJSON(status: .duplicate))
        let resolver = ResolverScript([.url("http://127.0.0.1:24734")], parkAfterImmediateCount: 1)
        let service = makeService(root: root, resolver: resolver.resolver)
        await configure(service)
        let syncing = Task { await service.sync() }
        await resolver.waitUntilParked()
        let receiptURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        #expect(IngestAcknowledgmentStore.read(from: receiptURL) == nil)
        #expect(try Data(contentsOf: file) == Data("audio".utf8))
        try Data("other".utf8).write(to: file)
        await resolver.releasePark()
        await syncing.value
        let bodies = store.snapshotRequestBodyData().compactMap { $0 }
        #expect(bodies.count == 2)
        if bodies.count == 2 { #expect(bodies[0] == bodies[1]) }
        // The receipt confirms the staged bytes, not the file as it is now: the changed file stays.
        #expect(try Data(contentsOf: file) == Data("other".utf8))

        // The next pass uploads the changed file and removes the segment.
        store.enqueue(body: uploadResponseJSON(status: .duplicate, sha: try sha256(of: file)))
        await service.sync()
        #expect(store.snapshotRequestBodyData().compactMap { $0 }.count == 3)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: segment.url.path))
    }

    @Test(arguments: ["present", "missing"])
    func explicitProbeRequiresReconciledCustody(custody: String) async throws {
        store.reset()
        let root = try makeTempDirectory("sync-explicit-probe")
        let segment = try makeSegment(root: root)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        store.registerRoute(path: IngestProtocolV3.uploadPath, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(entries: [("120000_300", nil, filename, sha, 5, custody)]))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24735") })
        await configure(service)
        do {
            let result = try await service.runLiveProbe(segmentURL: segment.url, day: day, segment: "120000_300")
            #expect(custody == "present")
            #expect(result.sha256 == sha)
        } catch {
            #expect(custody == "missing")
        }
    }

    @Test
    func idlePassOnTodayOnlyReadsTodayAndNoPastDays() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-idle-pass")
        let todayDate = Date()
        let today = IngestDayKey.string(from: todayDate)
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24736") })
        await configure(service)
        await service.sync()

        let requests = store.snapshotRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == IngestProtocolV3.segmentsDayPath(today))
    }

    @Test
    func postReceivedNotWrittenSets86400BoundAndYieldsSyncComplete() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-post-rnw")
        let seg = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        let rnwResponse = completeUploadResponseJSON(status: "ok", segment: "120000_300", descriptors: [(filename, filename, 5, sha, "received_not_written")])
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: rnwResponse)
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let progress = ProgressCollector()
        let clock = SyncTestClock()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24763") }, now: { clock.now() })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForSyncComplete()
        listen.cancel()

        #expect(progress.containsSyncComplete)
        #expect(!progress.containsOffline)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        #expect(IngestAcknowledgmentStore.read(from: ackURL) == nil)

        // Inside 86400: no second POST
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        clock.advance(by: 3600)
        await service.sync()
        #expect(store.snapshotRequests().compactMap { $0.url?.path } == [IngestProtocolV3.segmentsDayPath(today)])

        // After 86400 seconds: POSTs again
        store.reset()
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: rnwResponse)
        clock.advance(by: 86400)
        await service.sync()
        let pathsAfter = store.snapshotRequests().compactMap { $0.url?.path }
        #expect(pathsAfter.contains(IngestProtocolV3.uploadPath))
    }

    @Test
    func post500SegmentRemovedTwinContentConflict() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-post-seg-removed")
        let seg = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"status\":\"failed\",\"error\":\"Ingest request failed\",\"reason_code\":\"segment_removed\"}")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let clock = SyncTestClock()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24764") }, now: { clock.now() })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: seg.url.path))

        // No second POST after clock moves 24 h
        store.reset()
        clock.advance(by: 86400 * 2)
        let laterToday = IngestDayKey.string(from: clock.now())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(laterToday), body: segmentsDayJSON(entries: []))
        await service.sync()
        #expect(store.snapshotRequests().compactMap { $0.url?.path } == [IngestProtocolV3.segmentsDayPath(laterToday)])

        // Twin: 409 content_conflict is exactly one POST in failing pass, and one hour later is next POST
        store.reset()
        let root2 = try makeTempDirectory("sync-post-content-conflict")
        _ = try makeSegment(root: root2)
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 409, body: "{\"reason_code\":\"content_conflict\"}")
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let clock2 = SyncTestClock()
        let service2 = makeService(root: root2, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24764") }, now: { clock2.now() })
        await configure(service2)
        await service2.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)

        // 1 hour later: next POST
        store.reset()
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 409, body: "{\"reason_code\":\"content_conflict\"}")
        clock2.advance(by: 3601)
        await service2.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    @Test
    func post500JournalWriteFailedIsExactlyOnePOST() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-post-jw-failed")
        let seg = try makeSegment(root: root)
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"reason_code\":\"journal_write_failed\"}")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24765") })
        await configure(service)
        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent("120000_300_audio.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
    }

    @Test(arguments: [
        (403, "{\"reason_code\":\"linked_device_required\"}", ObserverHealthFailureReason.pairingRevoked),
        (426, "upgrade required", ObserverHealthFailureReason.journalNotServing),
        (409, "{\"reason_code\":\"foreign_stream_binding\"}", ObserverHealthFailureReason.journalRefused(reasonCode: "foreign_stream_binding")),
    ])
    func postDeviceScopedAnswersEndPassAndSetQuietHour(status: Int, body: String, expectedHealth: ObserverHealthFailureReason) async throws {
        store.reset()
        let root = try makeTempDirectory("sync-post-device-scoped")
        _ = try makeSegment(root: root, segmentName: "120000_300")
        _ = try makeSegment(root: root, segmentName: "120500_300")
        _ = try makeSegment(root: root, segmentName: "121000_300")
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: status, body: body)
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let clock = SyncTestClock()
        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24766") }, now: { clock.now() })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForOffline()
        listen.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(progress.offlineEvents.contains { $0.healthReason == expectedHealth })

        // Clock + 30 minutes: zero POSTs and exactly one GET segments/{today}
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        clock.advance(by: 1800)
        await service.sync()
        #expect(store.snapshotRequests().compactMap { $0.url?.path } == [IngestProtocolV3.segmentsDayPath(today)])
    }

    @Test
    func configureClearingQuietHourOn403() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-config-clear-quiet")
        _ = try makeSegment(root: root)
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 403, body: "{\"reason_code\":\"linked_device_required\"}")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let clock = SyncTestClock()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24767") }, now: { clock.now() })
        await configure(service)
        await service.sync()

        // Configure with same pairing does NOT clear quiet hour
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        await configure(service)
        await service.sync()
        #expect(store.snapshotRequests().compactMap { $0.url?.path } == [IngestProtocolV3.segmentsDayPath(today)])

        // Configure to journal B clears quiet hour and next pass POSTs
        store.reset()
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: uploadResponseJSON())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        await configureB(service)
        await service.sync()
        let paths = store.snapshotRequests().compactMap { $0.url?.path }
        #expect(paths.contains(IngestProtocolV3.uploadPath))
    }

    @Test(arguments: [
        (200, "<html>not json</html>"),
        (409, "not-json"),
        (502, ""),
    ])
    func transportFailuresAttempt3TimesThenLiveness(status: Int, body: String) async throws {
        store.reset()
        let root = try makeTempDirectory("sync-transport-liveness")
        _ = try makeSegment(root: root, segmentName: "120000_300")
        _ = try makeSegment(root: root, segmentName: "120500_300")
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: status, body: body)
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), statusCode: status, body: body)

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24768") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForOffline()
        listen.cancel()

        let requests = store.snapshotRequests()
        #expect(requests.filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 3)
        #expect(requests.filter { $0.url?.path == IngestProtocolV3.segmentsDayPath(today) }.count == 1)
        #expect(progress.containsOffline)
    }

    @Test
    func post503RetryableDoesNotSetQuietHour() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-post-503")
        _ = try makeSegment(root: root)
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 503, body: "{\"status\":\"retryable\",\"reason_code\":\"source_mutation_lock\"}")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24769") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForOffline()
        listen.cancel()

        #expect(progress.containsOffline)
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)

        // Next pass with clock unmoved POSTs again
        store.reset()
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 503, body: "{\"status\":\"retryable\",\"reason_code\":\"source_mutation_lock\"}")
        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
    }

    @Test
    func postContentConflictLadderAndReset() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-conflict-ladder")
        _ = try makeSegment(root: root)
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let clock = SyncTestClock()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24770") }, now: { clock.now() })
        await configure(service)

        // Answer 1
        store.reset()
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 409, body: "{\"reason_code\":\"content_conflict\"}")
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        await service.sync()

        // Answer 2 (after 1 hour)
        store.reset()
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 409, body: "{\"reason_code\":\"content_conflict\"}")
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        clock.advance(by: 3601)
        await service.sync()

        // Answer 3 (after another 1 hour)
        store.reset()
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 409, body: "{\"reason_code\":\"content_conflict\"}")
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        clock.advance(by: 3601)
        await service.sync()

        // After third, 1 hour later does NOT post (quiet is 86400)
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        clock.advance(by: 3601)
        await service.sync()
        let paths1 = store.snapshotRequests().compactMap { $0.url?.path }
        #expect(!paths1.contains(IngestProtocolV3.uploadPath))

        // 86400 seconds after third: posts again
        store.reset()
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 400, body: "{\"reason_code\":\"malformed_evidence_row\"}")
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        clock.advance(by: 86400)
        await service.sync()
        let paths2 = store.snapshotRequests().compactMap { $0.url?.path }
        #expect(paths2.contains(IngestProtocolV3.uploadPath))

        // One 400 resets the ladder: following bound is 1 hour, so pass 2 hours later POSTs again
        store.reset()
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: uploadResponseJSON())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        clock.advance(by: 7200)
        await service.sync()
        let paths3 = store.snapshotRequests().compactMap { $0.url?.path }
        #expect(paths3.contains(IngestProtocolV3.uploadPath))
    }

    @Test
    func postOnly409ContentConflictYieldsSyncCompleteNotOffline() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-post-409-complete")
        _ = try makeSegment(root: root)
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 409, body: "{\"reason_code\":\"content_conflict\"}")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24771") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForSyncComplete()
        listen.cancel()

        #expect(progress.containsSyncComplete)
        #expect(!progress.containsOffline)
    }

    @Test
    func idleAckedSegment500JournalReadFailedYieldsJournalRejectedDay() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-idle-500-jrf")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), statusCode: 500, body: "{\"status\":\"failed\",\"reason_code\":\"journal_read_failed\"}")

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24772") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForOffline()
        listen.cancel()

        #expect(progress.offlineEvents.contains {
            if case .journalRejectedDay(let d, let reason) = $0.healthReason {
                return d == today && reason == "journal_read_failed"
            }
            return false
        })
    }

    @Test
    func prechangeIngestAckFixtureLoadsAndReconcilesProof() async throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "prechange-ingest-ack", withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "prechange-ingest-ack", withExtension: "json")
        )
        let fixtureData = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        let ack = try decoder.decode(IngestAcknowledgment.self, from: fixtureData)

        #expect(ack.isValid)
        #expect(ack.day == "20260915")
        #expect(ack.submittedSegment == "120000_300")
        #expect(ack.storedSegmentKey == "120000_300")
        #expect(ack.payload.files.count == 1)
        let proof = try #require(ack.payload.files.first)
        #expect(proof.submitted == "120000_300_audio.m4a")
        #expect(proof.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(proof.size == 5)

        let root = try makeTempDirectory("sync-fixture-prechange")
        let segDir = root
            .appendingPathComponent("2026-09-15", isDirectory: true)
            .appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let mediaURL = segDir.appendingPathComponent("120000_300_audio.m4a")
        try Data("hello".utf8).write(to: mediaURL)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: "120000_300")
        try fixtureData.write(to: ackURL)

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 17
        components.hour = 12
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: components))

        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath("20260917"), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24744") }, now: { fixedNow })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: mediaURL.path))
        #expect(!FileManager.default.fileExists(atPath: segDir.path))
        let uploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.isEmpty)
    }

    @Test
    func confirmedSegmentWithDSStoreAndStagingTmpRemovedCompletely() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-dsstore-staging-tmp")
        let date = Date()
        let day = dayString(for: date)
        let segmentName = "120000_300"
        let dayDir = root.appendingPathComponent(dateFolderString(for: date), isDirectory: true)
        let segDir = dayDir.appendingPathComponent(segmentName, isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)

        let mediaURL = segDir.appendingPathComponent("\(segmentName)_audio.m4a")
        try Data("audio".utf8).write(to: mediaURL)
        let sha = try sha256(of: mediaURL)

        let dsStoreURL = segDir.appendingPathComponent(".DS_Store")
        try Data("ds_store_data".utf8).write(to: dsStoreURL)

        let tmpUUID = UUID().uuidString
        let tmpURL = segDir.appendingPathComponent(".\(segmentName)_ingest_ack.json.\(tmpUUID).tmp")
        try Data("tmp_data".utf8).write(to: tmpURL)

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: segmentName,
            storedSegmentKey: segmentName,
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "\(segmentName)_audio.m4a", sha256: sha, size: 5)],
                meta: [:]
            ),
            removedMedia: []
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: segmentName)
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24740") })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: segDir.path))
        #expect(FileManager.default.fileExists(atPath: dayDir.path))
        let uploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.isEmpty)
    }

    @Test
    func confirmedSegmentWithNonUUIDM4AIsRenamedToFailed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-non-uuid-m4a-failed")
        let date = Date()
        let day = dayString(for: date)
        let segmentName = "120000_300"
        let dayDir = root.appendingPathComponent(dateFolderString(for: date), isDirectory: true)
        let segDir = dayDir.appendingPathComponent(segmentName, isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)

        let mediaURL = segDir.appendingPathComponent("\(segmentName)_audio.m4a")
        try Data("audio".utf8).write(to: mediaURL)
        let sha = try sha256(of: mediaURL)

        let notesURL = segDir.appendingPathComponent("notes.m4a")
        try Data("notes_data".utf8).write(to: notesURL)

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: segmentName,
            storedSegmentKey: segmentName,
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "\(segmentName)_audio.m4a", sha256: sha, size: 5)],
                meta: [:]
            ),
            removedMedia: []
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: segmentName)
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24740") })
        await configure(service)
        await service.sync()

        let failedDir = dayDir.appendingPathComponent("\(segmentName).failed", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: segDir.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("notes.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("\(segmentName)_audio.m4a").path))
        #expect(FileManager.default.fileExists(atPath: dayDir.path))
        let uploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.isEmpty)
    }

    @Test
    func confirmedSegmentWithAckListingAbsentFileRemovesFolderWithoutUpload() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-ack-absent-file")
        let date = Date()
        let day = dayString(for: date)
        let segmentName = "120000_300"
        let dayDir = root.appendingPathComponent(dateFolderString(for: date), isDirectory: true)
        let segDir = dayDir.appendingPathComponent(segmentName, isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)

        let audioURL = segDir.appendingPathComponent("\(segmentName)_audio.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let audioSHA = try sha256(of: audioURL)

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: segmentName,
            storedSegmentKey: segmentName,
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [
                    IngestAcknowledgedFileProof(submitted: "\(segmentName)_audio.m4a", sha256: audioSHA, size: 5),
                    IngestAcknowledgedFileProof(submitted: "\(segmentName)_screen.mp4", sha256: "6ed8919ce20490a5e3ad8630a4fab69475297abd07db73918dd5f36fcfaeb11b", size: 100)
                ],
                meta: [:]
            ),
            removedMedia: []
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: segmentName)
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24740") })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: segDir.path))
        #expect(FileManager.default.fileExists(atPath: dayDir.path))
        let uploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploadRequests.isEmpty)
    }

    // MARK: - Confirmed removal: coverage, quarantine and retry

    @Test func transientClassifyErrorUploadsUncoveredAudioInsteadOfRemovingIt() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-transient-classify-receipt")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let audioURL = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let screenURL = seg.url.appendingPathComponent("120000_300_display_1_screen.mp4")
        try Data("screen".utf8).write(to: screenURL)
        let audioSHA = try sha256(of: audioURL)
        let screenSHA = try sha256(of: screenURL)
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.enqueue(body: completeUploadResponseJSON(descriptors: [
            (screenURL.lastPathComponent, screenURL.lastPathComponent, 6, screenSHA, "written"),
        ]))
        store.enqueue(body: completeUploadResponseJSON(descriptors: [
            (audioURL.lastPathComponent, audioURL.lastPathComponent, 5, audioSHA, "written"),
            (screenURL.lastPathComponent, screenURL.lastPathComponent, 6, screenSHA, "written"),
        ]))

        // Discovery fails to classify the audio once; at removal it classifies normally.
        let audioFailedOnce = MutexValue<Bool>(false)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24790") },
            classifyEntry: { url in
                if url.lastPathComponent == "120000_300_audio.m4a" {
                    let fail = audioFailedOnce.withLock { failed -> Bool in
                        if failed { return false }
                        failed = true
                        return true
                    }
                    if fail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                }
                return try syncTestClassifyByLstat(url)
            }
        )
        await configure(service)
        await service.sync()

        // Only the screen went up; the unsent audio is neither removed nor quarantined.
        let firstBodies = store.snapshotRequestBodyData().compactMap { $0 }
        #expect(firstBodies.count == 1)
        #expect(firstBodies.first.map { !String(decoding: $0, as: UTF8.self).contains("120000_300_audio.m4a") } == true)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(FileManager.default.fileExists(atPath: screenURL.path))
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))

        // The next pass uploads the audio with the screen, then removes the segment.
        await service.sync()
        let uploads = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(uploads.count == 2)
        let bodies = store.snapshotRequestBodyData().compactMap { $0 }
        #expect(bodies.last.map { String(decoding: $0, as: UTF8.self).contains("120000_300_audio.m4a") } == true)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
    }

    @Test func transientClassifyErrorOnSoleAudioIsNotQuarantinedAsRemnant() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-transient-classify-remnant")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let audioURL = seg.url.appendingPathComponent("120000_300_audio.m4a")
        let audioSHA = try sha256(of: audioURL)
        // A valid ack from the linked journal that does not name the audio.
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: seg.date),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_display_1_screen.mp4", sha256: String(repeating: "b", count: 64), size: 6)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))
        store.enqueue(body: uploadResponseJSON(filename: audioURL.lastPathComponent, sha: audioSHA, size: 5))

        let audioFailedOnce = MutexValue<Bool>(false)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24791") },
            classifyEntry: { url in
                if url.lastPathComponent == "120000_300_audio.m4a" {
                    let fail = audioFailedOnce.withLock { failed -> Bool in
                        if failed { return false }
                        failed = true
                        return true
                    }
                    if fail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                }
                return try syncTestClassifyByLstat(url)
            }
        )
        await configure(service)
        await service.sync()

        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.isEmpty == true)

        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
    }

    @Test func perSourceAudioListedAsUnreadableIsRemovedWithTheFolder() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-listed-per-source")
        let segDir = root.appendingPathComponent("2026-09-20", isDirectory: true).appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let audioURL = segDir.appendingPathComponent("120000_300_audio.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let perSourceURL = segDir.appendingPathComponent("120000_300_audio_AppleUSBAudioEngine_Vendor_Mic_123_1.m4a")
        try Data("per-source".utf8).write(to: perSourceURL)
        let meta: [String: IngestJSONValue] = [
            "unreadable_audio_sources": .object(["source_ids": .array([.string("AppleUSBAudioEngine:Vendor:Mic:123:1")])]),
        ]
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: "20260920",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: try sha256(of: audioURL), size: 5)],
                meta: meta
            )
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: "120000_300"))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .held })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: segDir.path))
        #expect(!FileManager.default.fileExists(atPath: segDir.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
        #expect(store.snapshotRequests().isEmpty)
    }

    @Test func readableUnlistedPerSourceAudioIsQuarantinedAndLeftAlone() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-unlisted-per-source")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let perSourceName = "120000_300_audio_AppleUSBAudioEngine_Vendor_Mic_123_1.m4a"
        try Data("per-source".utf8).write(to: seg.url.appendingPathComponent(perSourceName))
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.enqueue(body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24792") })
        await configure(service)
        await service.sync()

        let failedDir = seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed")
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(perSourceName).path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(filename).path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_300_ingest_ack.json").path))

        // The next pass neither uploads, retries nor calls the quarantined segment unprovable.
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        let next = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24792") })
        await configure(next)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await next.progressStream { collector.append(event) }
        }
        await next.sync()
        await collector.waitForSyncComplete()
        listen.cancel()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.isEmpty == true)
        #expect(collector.segmentUnprovableCount == 0)
        let uploadAttempted = collector.allEvents.contains {
            switch $0 {
            case .uploadStarted, .uploadRetrying, .uploadFailed: return true
            default: return false
            }
        }
        #expect(!uploadAttempted)
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(perSourceName).path))
    }

    @Test func rejectedSubfolderIsQuarantined() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-rejected-subfolder")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let rejectedDir = seg.url.appendingPathComponent("rejected", isDirectory: true)
        try FileManager.default.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
        try Data("rejected".utf8).write(to: rejectedDir.appendingPathComponent("silent_120000_300_audio_mic.m4a"))
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.enqueue(body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24793") })
        await configure(service)
        await service.sync()

        let failedDir = seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed")
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("rejected/silent_120000_300_audio_mic.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(filename).path))
    }

    @Test func renameFailureLeavesTheAckAndTheNextPassCompletes() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-rename-failure")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        try Data("keeper".utf8).write(to: seg.url.appendingPathComponent("extra.txt"))
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.enqueue(body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24794") },
            renameItem: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        )
        await configure(service)
        await service.sync()

        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        let failedDir = seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed")
        #expect(FileManager.default.fileExists(atPath: ackURL.path))
        #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent("extra.txt").path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.path))

        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        let next = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24794") })
        await configure(next)
        await next.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("extra.txt").path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_300_ingest_ack.json").path))
    }

    @Test func shaMismatchedReceiptKeepsTheSegment() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-sha-mismatch-receipt")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.enqueue(body: uploadResponseJSON(filename: filename, sha: String(repeating: "c", count: 64), size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24795") })
        await configure(service)
        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        #expect(IngestAcknowledgmentStore.read(from: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")) == nil)
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
    }

    @Test func segmentRemovedWithListedPerSourceAudioRemovesTheFolder() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-seg-removed-per-source")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        try Data(#"{"unreadable_audio_sources":{"source_ids":["AppleUSBAudioEngine:Vendor:Mic:123:1"]}}"#.utf8)
            .write(to: seg.url.appendingPathComponent("120000_300_meta.json"))
        try Data("per-source".utf8).write(to: seg.url.appendingPathComponent("120000_300_audio_AppleUSBAudioEngine_Vendor_Mic_123_1.m4a"))
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"status\":\"failed\",\"error\":\"Ingest request failed\",\"reason_code\":\"segment_removed\"}")

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24796") })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
    }

    @Test func segmentRemovedRemovesItsAckWithTheFolder() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-seg-removed-ack")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        // An ack from another journal is not a confirmation here, so the segment uploads.
        let otherAck = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB).value,
            day: dayString(for: seg.date),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: try sha256(of: seg.url.appendingPathComponent(filename)), size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(otherAck, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"status\":\"failed\",\"error\":\"Ingest request failed\",\"reason_code\":\"segment_removed\"}")

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24797") })
        await configure(service)
        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
    }

    @Test func segmentRemovedWithKeepersRemovesMediaBeforeTheRename() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-seg-removed-order")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let audioURL = seg.url.appendingPathComponent("120000_300_audio.m4a")
        try Data("keep".utf8).write(to: seg.url.appendingPathComponent("keeper.bin"))
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"status\":\"failed\",\"error\":\"Ingest request failed\",\"reason_code\":\"segment_removed\"}")

        // The media removal fails once: the folder keeps its name and a later pass retries.
        let mediaFailedOnce = MutexValue<Bool>(false)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24798") },
            removeItem: { url in
                if url.lastPathComponent == "120000_300_audio.m4a" {
                    let fail = mediaFailedOnce.withLock { failed -> Bool in
                        if failed { return false }
                        failed = true
                        return true
                    }
                    if fail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
                }
                guard Darwin.unlink(url.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        )
        await configure(service)
        await service.sync()

        let failedDir = seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed")
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.path))

        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 2)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("keeper.bin").path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_300_audio.m4a").path))
    }

    @Test func segmentRemovedWhenMetadataRemovalFailsKeepsMediaForTheNextPass() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-seg-removed-meta-throws")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let audioURL = seg.url.appendingPathComponent("120000_300_audio.m4a")
        try Data("{}".utf8).write(to: seg.url.appendingPathComponent("120000_300_meta.json"))
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"status\":\"failed\",\"error\":\"Ingest request failed\",\"reason_code\":\"segment_removed\"}")

        let metaFailedOnce = MutexValue<Bool>(false)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24799") },
            removeItem: { url in
                if url.lastPathComponent == "120000_300_meta.json" {
                    let fail = metaFailedOnce.withLock { failed -> Bool in
                        if failed { return false }
                        failed = true
                        return true
                    }
                    if fail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
                }
                guard Darwin.unlink(url.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        )
        await configure(service)
        await service.sync()

        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))

        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 2)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func failedAnswerWithoutReasonCodeKeepsTheSegment() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-500-failed-no-reason")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"status\":\"failed\",\"error\":\"Ingest request failed\"}")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24800") })
        await configure(service)
        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count >= 1)
        #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent("120000_300_audio.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: seg.url.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
    }

    @Test func resolverHeldStillRemovesAnAckedMatchingSegment() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-held-acked")
        let seg = try makeSegment(root: root, date: Date().addingTimeInterval(-172800), segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: seg.date),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: try sha256(of: seg.url.appendingPathComponent(filename)), size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .held })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(store.snapshotRequests().isEmpty)
    }

    @Test func deviceQuietWindowStillRemovesAnAckedMatchingSegment() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-quiet-acked")
        _ = try makeSegment(root: root, segmentName: "121000_300")
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 403, body: "{\"reason_code\":\"linked_device_required\"}")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let requestsAtRemoval = MutexValue<Int?>(nil)
        let store = self.store
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24801") },
            beforeRemovalStep: {
                let count = store.snapshotRequests().count
                requestsAtRemoval.withLock { if $0 == nil { $0 = count } }
            }
        )
        await configure(service)
        await service.sync()  // 403: the device-quiet window starts

        let seg = try makeSegment(root: root, date: Date().addingTimeInterval(-172800), segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: seg.date),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: try sha256(of: seg.url.appendingPathComponent(filename)), size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        // The removal needs no request; the only request of the pass is the quiet window's probe of today.
        #expect(requestsAtRemoval.withLock { $0 } == 0)
        #expect(store.snapshotRequests().compactMap { $0.url?.path } == [IngestProtocolV3.segmentsDayPath(today)])
    }

    @Test func upgradeNoMediaFolderWithUnreadableAckIsRemovedWithoutNetwork() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-upgrade-unreadable-ack")
        let segDir = root.appendingPathComponent("2026-09-10", isDirectory: true).appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: segDir.appendingPathComponent("120000_300_meta.json"))
        try Data("{not json".utf8).write(to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: "120000_300"))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .held })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: segDir.path))
        #expect(!FileManager.default.fileExists(atPath: segDir.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
        #expect(store.snapshotRequests().isEmpty)
    }

    @Test func upgradeNoMediaFolderWithAnotherJournalsAckIsRemovedWithoutNetwork() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-upgrade-other-journal-ack")
        let segDir = root.appendingPathComponent("2026-09-10", isDirectory: true).appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: segDir.appendingPathComponent("120000_300_meta.json"))
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB).value,
            day: "20260910",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: String(repeating: "a", count: 64), size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: "120000_300"))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .held })
        await configure(service)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: segDir.path))
        #expect(!FileManager.default.fileExists(atPath: segDir.deletingLastPathComponent().appendingPathComponent("120000_300.failed").path))
        #expect(store.snapshotRequests().isEmpty)
    }

    @Test func upgradeAckedFolderWithUnlistedPerSourceAudioIsQuarantined() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-upgrade-unlisted-per-source")
        let segDir = root.appendingPathComponent("2026-09-10", isDirectory: true).appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let audioURL = segDir.appendingPathComponent("120000_300_audio.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let perSourceName = "120000_300_audio_BuiltInMicrophoneDevice.m4a"
        try Data("per-source".utf8).write(to: segDir.appendingPathComponent(perSourceName))
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: "20260910",
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: try sha256(of: audioURL), size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: "120000_300"))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .held })
        await configure(service)
        await service.sync()

        let failedDir = segDir.deletingLastPathComponent().appendingPathComponent("120000_300.failed")
        #expect(!FileManager.default.fileExists(atPath: segDir.path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(perSourceName).path))
        #expect(!FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_300_audio.m4a").path))
        #expect(store.snapshotRequests().isEmpty)
    }

    @Test func journalSwitchMidRemovalReuploadsToTheLinkedJournal() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-switch-mid-removal")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.registerRoute(path: IngestProtocolV3.uploadPath, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let pairing = pairingB
        let fingerprint = tunnelJournalConnectionFingerprint(for: pairingB)
        let serviceHolder = MutexValue<SyncService?>(nil)
        let switched = MutexValue<Bool>(false)
        let service = makeService(
            root: root,
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24802") },
            beforeRemovalStep: {
                let shouldSwitch = switched.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if shouldSwitch, let s = serviceHolder.withLock({ $0 }) {
                    await s.configure(pairingIdentity: pairing, journalFingerprint: fingerprint, syncPaused: false)
                }
            }
        )
        serviceHolder.withLock { $0 = service }
        await configure(service)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream { collector.append(event) }
        }
        await service.sync()

        // The switch stopped the removal: the segment and the first journal's ack remain.
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        #expect(IngestAcknowledgmentStore.read(from: ackURL)?.journalFingerprint == tunnelJournalConnectionFingerprint(for: pairingA).value)

        // The ack is not the linked journal's, so the next pass uploads to it before removing.
        await service.sync()
        listen.cancel()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 2)
        #expect(collector.uploadSucceededFingerprints.last == fingerprint.value)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test func failedFolderCollisionPicksAnUnusedNameAndKeepsExistingOnes() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-failed-collision")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let dayDir = seg.url.deletingLastPathComponent()
        // An earlier quarantine of the same clock hour: one empty, one holding a file.
        let existingEmpty = dayDir.appendingPathComponent("120000_300.failed", isDirectory: true)
        try FileManager.default.createDirectory(at: existingEmpty, withIntermediateDirectories: true)
        let existingFull = dayDir.appendingPathComponent("120000_300.2.failed", isDirectory: true)
        try FileManager.default.createDirectory(at: existingFull, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existingFull.appendingPathComponent("old.txt"))
        try Data("keeper".utf8).write(to: seg.url.appendingPathComponent("extra.txt"))
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.enqueue(body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24803") })
        await configure(service)
        await service.sync()

        let newFailed = dayDir.appendingPathComponent("120000_300.3.failed", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: seg.url.path))
        #expect(FileManager.default.fileExists(atPath: newFailed.appendingPathComponent("extra.txt").path))
        #expect(FileManager.default.fileExists(atPath: newFailed.appendingPathComponent("120000_300_ingest_ack.json").path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: existingEmpty.path))?.isEmpty == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: existingFull.path) == ["old.txt"])

        // Discovery skips the numbered quarantine folder: the next pass uploads nothing.
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: newFailed.appendingPathComponent("extra.txt").path))
    }

    private func uploadResponseJSON(
        status: IngestProtocolV3.UploadStatus = .ok,
        submitted: String = "120000_300",
        stored: String = "120000_300",
        filename: String? = nil,
        sha: String = "6ed8919ce20490a5e3ad8630a4fab69475297abd07db73918dd5f36fcfaeb11b",
        size: UInt64 = 5
    ) -> String {
        let submittedFile = filename ?? "\(submitted)_audio.m4a"
        let writtenFile = filename ?? "\(stored)_audio.m4a"
        let disp = status == .duplicate ? "already_held" : "written"
        return completeUploadResponseJSON(
            status: status.rawValue,
            segment: stored,
            existingSegment: status == .duplicate ? stored : nil,
            segmentOriginal: status == .collision ? submitted : nil,
            descriptors: [(submittedFile, writtenFile, size, sha, disp)]
        )
    }

    private func makeService(
        root: URL,
        resolver: HomeBaseURLResolver,
        now: (@escaping @Sendable () -> Date) = Date.init,
        beforeRemovalStep: (@escaping @Sendable () async -> Void) = {},
        listDirectory: (@Sendable (URL) throws -> [URL])? = nil,
        classifyEntry: (@Sendable (URL) throws -> SyncService.DiscoveredEntryKind)? = nil,
        removeItem: (@Sendable (URL) throws -> Void)? = nil,
        renameItem: (@Sendable (URL, URL) throws -> Void)? = nil
    ) -> SyncService {
        SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: resolver,
            now: now,
            retryDelays: Array(repeating: 0, count: 10),
            beforeRemovalStep: beforeRemovalStep,
            removeItem: removeItem ?? { url in
                guard Darwin.unlink(url.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            },
            renameItem: renameItem ?? { source, destination in
                guard Darwin.renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            },
            listDirectory: listDirectory ?? { url in
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            },
            classifyEntry: classifyEntry ?? syncTestClassifyByLstat
        )
    }

    private func makeHoldingService(
        root: URL,
        resolver: HomeBaseURLResolver,
        now: (@escaping @Sendable () -> Date) = Date.init
    ) -> SyncService {
        SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: holdingURLProtocolConfiguration()),
            resolver: resolver,
            now: now,
            retryDelays: Array(repeating: 0, count: 10)
        )
    }

    private var pairingA: TunnelPairingIdentity {
        TunnelPairingIdentity(instanceID: "instance", fingerprint: "fingerprint")
    }

    private var pairingB: TunnelPairingIdentity {
        TunnelPairingIdentity(instanceID: "other-instance", fingerprint: "other-fingerprint")
    }

    private func configure(_ service: SyncService) async {
        await service.configure(
            pairingIdentity: pairingA,
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA),
            syncPaused: false
        )
    }

    private func configureB(_ service: SyncService) async {
        await service.configure(
            pairingIdentity: pairingB,
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB),
            syncPaused: false
        )
    }

    private func applyStaleness(_ variant: ContextStaleness, to service: SyncService) async {
        switch variant {
        case .switchToB:
            await service.configure(
                pairingIdentity: pairingB,
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB),
                syncPaused: false
            )
        case .pairingAFingerprintNil:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: nil,
                syncPaused: false
            )
        case .pairingAFingerprintMalformed:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: JournalConnectionFingerprint(value: "not-a-fingerprint"),
                syncPaused: false
            )
        case .pairingAFingerprintEqualsB:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingB),
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
                syncPaused: false
            )
        case .pairingAFingerprintNil:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: nil,
                syncPaused: false
            )
        case .pairingAFingerprintMalformed:
            await service.configure(
                pairingIdentity: pairingA,
                journalFingerprint: JournalConnectionFingerprint(value: "not-a-fingerprint"),
                syncPaused: false
            )
        case .nilPairingWithFingerprint:
            await service.configure(
                pairingIdentity: nil,
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA),
                syncPaused: false
            )
        case .bothNil:
            await service.configure(
                pairingIdentity: nil,
                journalFingerprint: nil,
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

    private func makeUnuploadableSegment(root: URL, date: Date = Date(), segmentName: String = "130000_300") throws -> (url: URL, date: Date) {
        let directory = root
            .appendingPathComponent(dateFolderString(for: date), isDirectory: true)
            .appendingPathComponent(segmentName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("\(segmentName)_meta.json"))
        return (directory, date)
    }

    private func segmentsDayJSON(key: String, filename: String, sha: String, size: Int) -> String {
        segmentsDayJSON(entries: [(key, nil, filename, sha, size, "present")])
    }

    private func segmentsDayJSON(detailedEntries: [(key: String, originalKey: String?, name: String, submittedName: String?, sha: String, size: Int, status: String)]) -> String {
        var itemsByKey: [String: (originalKey: String?, files: [(String, String?, String, Int, String)])] = [:]
        var keyOrder: [String] = []
        for (key, originalKey, name, submittedName, sha, size, status) in detailedEntries {
            if itemsByKey[key] == nil {
                keyOrder.append(key)
                itemsByKey[key] = (originalKey, [])
            }
            itemsByKey[key]?.files.append((name, submittedName, sha, size, status))
        }
        let items = keyOrder.map { key in
            let info = itemsByKey[key]!
            let original = info.originalKey.map { ",\"original_key\":\"\($0)\"" } ?? ""
            let files = info.files.map { name, submittedName, sha, size, status in
                let subName = submittedName.map { ",\"submitted_name\":\"\($0)\"" } ?? ""
                return "{\"name\":\"\(name)\"\(subName),\"sha256\":\"\(sha)\",\"size\":\(size),\"status\":\"\(status)\"}"
            }.joined(separator: ",")
            return "{\"key\":\"\(key)\",\"observed\":true,\"files\":[\(files)]\(original)}"
        }.joined(separator: ",")
        return "{\"protocol_version\":3,\"total\":\(keyOrder.count),\"items\":[\(items)]}"
    }

    private func segmentsDayJSON(entries: [(String, String?, String, String, Int, String)] = []) -> String {
        segmentsDayJSON(detailedEntries: entries.map { (key: $0.0, originalKey: $0.1, name: $0.2, submittedName: $0.2, sha: $0.3, size: $0.4, status: $0.5) })
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
}

@Sendable private func syncTestClassifyByLstat(_ url: URL) throws -> SyncService.DiscoveredEntryKind {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let fileType = info.st_mode & mode_t(S_IFMT)
    if fileType == mode_t(S_IFDIR) {
        return .directory
    } else if fileType == mode_t(S_IFREG) {
        return .regularFile
    } else {
        return .unsupported
    }
}

private final class MutexValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class SyncTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date()) {
        self.current = start
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(interval)
        }
    }

    func now() -> Date {
        lock.withLock {
            current
        }
    }
}

private actor ResolverScript {
    private var values: [ResolvedHomeBase]
    private var immediateRemaining: Int
    private var shouldPark: Bool
    private var parkResume: CheckedContinuation<Void, Never>?
    private var isParked = false

    nonisolated var resolver: HomeBaseURLResolver {
        HomeBaseURLResolver { await self.next() }
    }

    init(_ values: [ResolvedHomeBase], parkAfterImmediateCount: Int? = nil) {
        self.values = values
        self.immediateRemaining = parkAfterImmediateCount ?? 0
        self.shouldPark = parkAfterImmediateCount != nil
    }

    func replace(with values: [ResolvedHomeBase]) { self.values = values }

    func waitUntilParked(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isParked { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the suspended resolver")
    }

    func releasePark() {
        shouldPark = false
        isParked = false
        if let resume = parkResume {
            parkResume = nil
            resume.resume()
        }
    }

    private func next() async -> ResolvedHomeBase {
        if shouldPark {
            if immediateRemaining > 0 {
                immediateRemaining -= 1
            } else {
                shouldPark = false
                isParked = true
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.parkResume = cont
                }
                isParked = false
            }
        }
        if values.count > 1 {
            return values.removeFirst()
        }
        return values.first ?? .held
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SyncService.ProgressEvent] = []
    func append(_ event: SyncService.ProgressEvent) {
        lock.withLock { events.append(event) }
    }

    var allEvents: [SyncService.ProgressEvent] {
        lock.withLock { events }
    }

    var containsConfigChangedFailure: Bool {
        lock.withLock {
            events.contains {
                guard case .uploadFailed(_, _, let reason, _) = $0 else { return false }
                return reason == .configChanged
            }
        }
    }

    var containsUploadSucceeded: Bool {
        lock.withLock {
            events.contains {
                if case .uploadSucceeded = $0 { return true }
                return false
            }
        }
    }

    var containsUploadFailed: Bool {
        lock.withLock {
            events.contains {
                if case .uploadFailed = $0 { return true }
                return false
            }
        }
    }

    var uploadSucceededFingerprint: String? {
        lock.withLock {
            for event in events {
                if case .uploadSucceeded(_, let fingerprint) = event {
                    return fingerprint
                }
            }
            return nil
        }
    }

    var uploadSucceededFingerprints: [String] {
        lock.withLock {
            events.compactMap {
                if case .uploadSucceeded(_, let fingerprint) = $0 {
                    return fingerprint
                }
                return nil
            }
        }
    }

    var segmentUnprovableCount: Int {
        lock.withLock {
            events.filter {
                if case .segmentUnprovable = $0 { return true }
                return false
            }.count
        }
    }

    var containsSyncComplete: Bool {
        lock.withLock {
            events.contains { if case .syncComplete = $0 { return true }; return false }
        }
    }

    var containsOffline: Bool {
        lock.withLock {
            events.contains { if case .offline = $0 { return true }; return false }
        }
    }

    var offlineEvents: [(error: String, healthReason: ObserverHealthFailureReason, requestedPath: String)] {
        lock.withLock {
            events.compactMap {
                if case .offline(let error, let healthReason, let path) = $0 {
                    return (error, healthReason, path)
                }
                return nil
            }
        }
    }

    func offlinePath() -> String? {
        lock.withLock {
            for event in events {
                if case .offline(_, _, let path) = event {
                    return path
                }
            }
            return nil
        }
    }

    func waitForSyncComplete(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if lock.withLock({ events.contains { if case .syncComplete = $0 { return true }; return false } }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for sync completion")
    }

    func waitForConfigChangedFailure(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if containsConfigChangedFailure { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for configuration-change failure")
    }

    func waitForUploadSucceeded(timeout: Duration = .seconds(5)) async {
        if containsUploadSucceeded { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if containsUploadSucceeded { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForOffline(timeout: Duration = .seconds(5)) async {
        if lock.withLock({ events.contains { if case .offline = $0 { return true }; return false } }) {
            return
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if lock.withLock({ events.contains { if case .offline = $0 { return true }; return false } }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForSegmentUnprovable(timeout: Duration = .seconds(5)) async {
        if segmentUnprovableCount > 0 { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if segmentUnprovableCount > 0 { return }
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
