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

    @Test(arguments: [-1, 0, 1, 2], ["present", "processed", "missing", "unknown"]) func subsetDeletionPreservesNonMediaAndDirectories(retention: Int, custody: String) async throws {
        store.reset()
        let root = try makeTempDirectory("sync-subset-deletion")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let day = dayString(for: pastDate)
        let dateFolder = dateFolderString(for: pastDate)
        let dateDir = root.appendingPathComponent(dateFolder, isDirectory: true)
        let segmentDir = dateDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)

        let screenURL = segmentDir.appendingPathComponent("120000_300_display_1_screen.mp4")
        let audioURL = segmentDir.appendingPathComponent("120000_300_audio.m4a")
        let metaURL = segmentDir.appendingPathComponent("120000_300_meta.json")
        let systemAudioURL = segmentDir.appendingPathComponent("120000_300_audio_system.m4a")
        let unrelatedURL = segmentDir.appendingPathComponent("unrelated.txt")
        let nestedDir = segmentDir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let childURL = nestedDir.appendingPathComponent("child.txt")

        try Data("screen-bytes".utf8).write(to: screenURL)
        try Data("audio-bytes".utf8).write(to: audioURL)
        let metaBytes = Data(#"{"unreadable_audio_sources":{}}"#.utf8)
        try metaBytes.write(to: metaURL)
        let systemBytes = Data("system-audio-bytes".utf8)
        try systemBytes.write(to: systemAudioURL)
        let unrelatedBytes = Data("unrelated-junk".utf8)
        try unrelatedBytes.write(to: unrelatedURL)
        let childBytes = Data("nested-child-bytes".utf8)
        try childBytes.write(to: childURL)

        let mediaDirectory = segmentDir.appendingPathComponent("nested_screen.mp4", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try childBytes.write(to: mediaDirectory.appendingPathComponent("keep.bin"))
        let mediaLink = segmentDir.appendingPathComponent("linked_screen.mp4")
        try FileManager.default.createSymbolicLink(at: mediaLink, withDestinationURL: childURL)

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
                meta: ["unreadable_audio_sources": .object([:])]
            )
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentDir, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        // Mock reconciliation query indicating server holds both upload media files
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(
            entries: [
                ("120000_300", nil, "120000_300_display_1_screen.mp4", screenSHA, 12, custody),
                ("120000_300", nil, "120000_300_audio.m4a", audioSHA, 11, custody),
            ]
        ))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24683") })
        await configure(service, cacheRetentionDays: retention)

        await service.sync()

        // Screen and combined audio must be deleted
        #expect(FileManager.default.fileExists(atPath: screenURL.path) == !(retention >= 0 && retention < 2 && (custody == "present" || custody == "processed")))
        #expect(FileManager.default.fileExists(atPath: audioURL.path) == !(retention >= 0 && retention < 2 && (custody == "present" || custody == "processed")))

        // Non-media, metadata, excluded audio, nested dir, and segment/date directories must remain byte-for-byte
        #expect(FileManager.default.fileExists(atPath: metaURL.path) == true)
        #expect(try Data(contentsOf: metaURL) == metaBytes)

        #expect(FileManager.default.fileExists(atPath: systemAudioURL.path) == true)
        #expect(try Data(contentsOf: systemAudioURL) == systemBytes)

        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path) == true)
        #expect(try Data(contentsOf: unrelatedURL) == unrelatedBytes)

        #expect(FileManager.default.fileExists(atPath: childURL.path) == true)
        #expect(try Data(contentsOf: childURL) == childBytes)

        #expect(FileManager.default.fileExists(atPath: segmentDir.path) == true)
        #expect(FileManager.default.fileExists(atPath: dateDir.path) == true)
        #expect(try Data(contentsOf: mediaDirectory.appendingPathComponent("keep.bin")) == childBytes)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mediaLink.path) == childURL.path)
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

    @Test func sizeMismatchRetainsSegmentAndUploads() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-size-mismatch")
        let segment = try makeSegment(root: root)
        let day = dayString(for: segment.date)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))
        store.enqueue(statusCode: 200, body: uploadResponseJSON())
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24685") })
        await configure(service)

        await service.sync()

        #expect(FileManager.default.fileExists(atPath: segment.url.path))
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

    @Test func noSelectableFilesDoesNotBlockDaySyncedMark() async throws {
        store.reset()
        let date = try #require(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let root = try makeTempDirectory("sync-no-selectable-files")
        let segment = try makeUnuploadableSegment(root: root, date: date, segmentName: "120000_300")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24690") })
        await configure(service, cacheRetentionDays: 0)

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
        let day = dayString(for: real.date)
        let filename = "110000_300_audio.m4a"
        let sha = try sha256(of: real.url.appendingPathComponent(filename))
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24691") })
        await configure(service, cacheRetentionDays: 0)

        // Pass 1: nothing on the server yet. The real segment uploads; the poison segment
        // is skipped without ever reaching the network.
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
        #expect(FileManager.default.fileExists(atPath: real.url.path))
        #expect(FileManager.default.fileExists(atPath: poison.url.path))

        // Pass 2: acknowledgment was saved in Pass 1. Cleanup runs and removes the real segment's media file.
        store.reset()
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(key: "110000_300", filename: filename, sha: sha, size: 5))
        await service.sync()

        #expect(FileManager.default.fileExists(atPath: real.url.appendingPathComponent(filename).path) == false)
        #expect(FileManager.default.fileExists(atPath: real.url.path) == true)
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

        #expect(collector.segmentUnprovableCount == 1)
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
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == true)
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
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == true)
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
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == true)
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
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == true)
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
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == true)
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
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == true)
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
        await configure(service, cacheRetentionDays: 0)
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
        #expect(FileManager.default.fileExists(atPath: validSegment.url.appendingPathComponent(filename).path) == true)
        let validAckURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: validSegment.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: validAckURL.path) == true)

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
        let validAckURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: validSegment.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: validAckURL.path) == true)

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
        let seg1AckURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg1.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: seg1AckURL.path) == true)

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
        let seg1AckURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg1.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: seg1AckURL.path) == true)

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
    }

    @Test func discoveryUploadMediaChildClassifyErrorRecordsFailureAndFailsClosed() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-media-classify-err")
        let seg = try makeSegment(root: root, segmentName: "120000_300")
        let screenURL = seg.url.appendingPathComponent("120000_300_display_1_screen.mp4")
        try Data("screen".utf8).write(to: screenURL)
        let audioURL = seg.url.appendingPathComponent("120000_300_audio.m4a")

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
        let segAckURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: segAckURL.path) == true)

        // Pass 2: default service recovers; uploads entire segment (including previously omitted audio)
        store.reset()
        store.enqueue(statusCode: 200, body: completeUploadResponseJSON(
            descriptors: [
                ("120000_300_audio.m4a", "120000_300_audio.m4a", 5, audioSHA, "written"),
                ("120000_300_display_1_screen.mp4", "120000_300_display_1_screen.mp4", 6, screenSHA, "written"),
            ]
        ))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24750") })
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

        let pass2UploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(pass2UploadRequests.count == 1)
        let bodies = store.snapshotRequestBodyData().compactMap { $0 }
        let bodyString = String(data: bodies[0], encoding: .utf8) ?? ""
        #expect(bodyString.contains("120000_300_audio.m4a") == true)
        #expect(bodyString.contains("120000_300_display_1_screen.mp4") == true)
        #expect(collector2.containsSyncComplete == true)
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
        let classifiedNames = Set(counter.all.map(\.lastPathComponent))
        #expect(classifiedNames.contains("120000_300_audio.m4a") == true)
        #expect(classifiedNames.contains("120000_300_meta.json") == false)
        #expect(classifiedNames.contains("120000_300_audio_system.m4a") == false)
        #expect(classifiedNames.contains("stray.txt") == false)
    }

    @Test func discoveryDateListingFailureSkipsCleanupOfEligibleSibling() async throws {
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
            )
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
            )
        )
        try IngestAcknowledgmentStore.write(ack2, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg2.url, segment: "120000_300"))

        // Pass 1: listDirectory throws on folder2; two-read facts for day1 are ready
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day1), body: segmentsDayJSON(key: "120000_300", filename: "120000_300_audio.m4a", sha: sha1, size: 5))

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
        await configure(service, cacheRetentionDays: 0)
        let collector = ProgressCollector()
        let listen = Task {
            for await event in await service.progressStream {
                collector.append(event)
            }
        }
        await service.sync()
        await collector.waitForOffline()
        listen.cancel()

        #expect(FileManager.default.fileExists(atPath: audio1.path) == true)
        #expect(collector.offlineEvents.count == 1)
        #expect(collector.containsSyncComplete == false)
        let pass1UploadRequests = store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }
        #expect(pass1UploadRequests.isEmpty)

        // Pass 2: default service on same root deletes both eligible siblings
        store.reset()
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day1), body: segmentsDayJSON(key: "120000_300", filename: "120000_300_audio.m4a", sha: sha1, size: 5))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day2), body: segmentsDayJSON(key: "120000_300", filename: "120000_300_audio.m4a", sha: sha2, size: 5))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24756") })
        await configure(service2, cacheRetentionDays: 0)
        let collector2 = ProgressCollector()
        let listen2 = Task {
            for await event in await service2.progressStream {
                collector2.append(event)
            }
        }
        await service2.sync()
        await collector2.waitForSyncComplete()
        listen2.cancel()

        #expect(FileManager.default.fileExists(atPath: audio1.path) == false)
        #expect(FileManager.default.fileExists(atPath: audio2.path) == false)
        #expect(collector2.containsSyncComplete == true)
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

        // Ack covering BOTH audio and screen files
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [
                    IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: audioSHA, size: 5),
                    IngestAcknowledgedFileProof(submitted: "120000_300_display_1_screen.mp4", sha256: screenSHA, size: UInt64(screenData.count)),
                ],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(
            entries: [
                ("120000_300", nil, "120000_300_audio.m4a", audioSHA, 5, "present"),
                ("120000_300", nil, "120000_300_display_1_screen.mp4", screenSHA, screenData.count, "present"),
            ]
        ))

        let resolver = ResolverScript([.url("http://127.0.0.1:24758"), .url("http://127.0.0.1:24758")], parkAfterImmediateCount: 0)
        let service = makeService(root: root, resolver: resolver.resolver)
        await configure(service, cacheRetentionDays: 0)

        let syncing = Task { await service.sync() }
        await resolver.waitUntilParked()

        // Plant late screen media file while sync is parked after discovery
        try screenData.write(to: screenURL)

        await resolver.releasePark()
        await syncing.value

        // Pass 1: snapshotted audio file deleted; late screen file remains
        #expect(FileManager.default.fileExists(atPath: audioFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: screenURL.path) == true)

        // Pass 2: subsequent sync discovers and cleans up the late screen file
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(
            entries: [
                ("120000_300", nil, "120000_300_audio.m4a", audioSHA, 5, "present"),
                ("120000_300", nil, "120000_300_display_1_screen.mp4", screenSHA, screenData.count, "present"),
            ]
        ))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24758") })
        await configure(service2, cacheRetentionDays: 0)
        await service2.sync()

        #expect(FileManager.default.fileExists(atPath: screenURL.path) == false)
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
        await configure(service, cacheRetentionDays: 0)

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
        await configure(service2, cacheRetentionDays: 0)
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
        await configure(service, cacheRetentionDays: 0)
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
        await configure(service, cacheRetentionDays: 0)
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
            cacheRetentionDays: -1,
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
        await configure(service)
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
        await configure(service, cacheRetentionDays: 0)

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
    }

    @Test func idempotencyWithAcknowledgedReceiptsSkipsUpload() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-ack-idempotent")
        let segment = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))

        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: "120000_300",
            stored: "120000_300",
            filename: filename,
            sha: sha,
            size: 5
        ))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24607") })
        await configure(service)

        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)

        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == true)
        let ack = IngestAcknowledgmentStore.read(from: ackURL)
        #expect(ack?.payload.files.count == 1)

        // Pass 2: valid acknowledgment on disk -> no upload request!
        store.reset()
        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 0)
    }

    @Test func partialSegmentOffloadAndSuccessorWrite() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-partial-offload")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let day = dayString(for: pastDate)
        let dateFolder = dateFolderString(for: pastDate)
        let dateDir = root.appendingPathComponent(dateFolder, isDirectory: true)
        let segmentDir = dateDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)

        let audioURL = segmentDir.appendingPathComponent("120000_300_audio.m4a")
        try Data("audio-1".utf8).write(to: audioURL)
        let audioSHA = try sha256(of: audioURL)

        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: "120000_300",
            stored: "120000_300",
            filename: "120000_300_audio.m4a",
            sha: audioSHA,
            size: 7
        ))

        store.enqueue(statusCode: 200, body: segmentsDayJSON(key: "120000_300", filename: audioURL.lastPathComponent, sha: audioSHA, size: 7))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24608") })
        await configure(service, cacheRetentionDays: 0)

        // Pass 1: uploads audio, then cleanup deletes audio file (without modifying ack sidecar)
        await service.sync()
        #expect(FileManager.default.fileExists(atPath: audioURL.path) == false)

        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentDir, segment: "120000_300")
        let ack1 = IngestAcknowledgmentStore.read(from: ackURL)
        #expect(ack1?.payload.files.count == 1)
        #expect(ack1?.payload.files.first?.submitted == "120000_300_audio.m4a")
        #expect(ack1?.removedMedia.isEmpty == true)

        // Now add a second media file (screen) to the segment
        let screenURL = segmentDir.appendingPathComponent("120000_300_display_1_screen.mp4")
        try Data("screen-2".utf8).write(to: screenURL)
        let screenSHA = try sha256(of: screenURL)

        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: "120000_300",
            stored: "120000_300",
            filename: "120000_300_display_1_screen.mp4",
            sha: screenSHA,
            size: 8
        ))

        await configure(service, cacheRetentionDays: -1) // keep screen local
        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        let ack2 = IngestAcknowledgmentStore.read(from: ackURL)
        #expect(ack2?.payload.files.count == 1)
        #expect(ack2?.payload.files.first?.submitted == "120000_300_display_1_screen.mp4")
        #expect(ack2?.removedMedia.count == 1)
        #expect(ack2?.removedMedia.first?.submitted == "120000_300_audio.m4a")
    }

    @Test func journalFingerprintMismatchForcesReupload() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-fingerprint-mismatch")
        let segment = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: segment.url.appendingPathComponent(filename))

        store.enqueue(statusCode: 200, body: uploadResponseJSON(
            status: .ok,
            submitted: "120000_300",
            stored: "120000_300",
            filename: filename,
            sha: sha,
            size: 5
        ))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24609") })
        await configure(service) // Journal A

        await service.sync()
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)

        // Switch to Journal B
        store.reset()
        await configureB(service)
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
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        let ack = IngestAcknowledgmentStore.read(from: ackURL)
        #expect(ack?.journalFingerprint == tunnelJournalConnectionFingerprint(for: pairingB).value)
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
            )
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentDir, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(
            entries: [
                ("120000_300", nil, "120000_300_display_1_screen.mp4", screenSHA, 12, "present"),
                ("120000_300", nil, "120000_300_audio.m4a", audioSHA, 11, "present"),
            ]
        ))

        struct PermissionDeniedError: Error {}

        // Pass 1: removeItem throws on screen file, succeeds on audio file
        let service1 = SyncService(
            storageManager: StorageManager(baseDirectory: root),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24610") },
            retryDelays: Array(repeating: 0, count: 10),
            removeItem: { url in
                if url.lastPathComponent.contains("screen") {
                    throw PermissionDeniedError()
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        await configure(service1, cacheRetentionDays: 0)
        await service1.sync()

        #expect(FileManager.default.fileExists(atPath: screenURL.path) == true)
        #expect(FileManager.default.fileExists(atPath: audioURL.path) == false)
        // Acknowledgment on disk must NOT be modified
        let diskAck1 = IngestAcknowledgmentStore.read(from: ackURL)
        #expect(diskAck1?.payload.files.count == 2)

        // Pass 2: removeItem succeeds on all files
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(
            entries: [
                ("120000_300", nil, "120000_300_display_1_screen.mp4", screenSHA, 12, "present"),
                ("120000_300", nil, "120000_300_audio.m4a", audioSHA, 11, "present"),
            ]
        ))

        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24610") })
        await configure(service2, cacheRetentionDays: 0)
        await service2.sync()

        #expect(FileManager.default.fileExists(atPath: screenURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: audioURL.path) == false)
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 0)
    }

    @Test func settledRemnantIsSilentNoOpWithoutUnprovableOrPost() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-settled-remnant")
        let pastDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let day = dayString(for: pastDate)
        let dateFolder = dateFolderString(for: pastDate)
        let dateDir = root.appendingPathComponent(dateFolder, isDirectory: true)
        let segmentDir = dateDir.appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)

        let metaURL = segmentDir.appendingPathComponent("120000_300_meta.json")
        try Data(#"{"key":"value"}"#.utf8).write(to: metaURL)

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
            )
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentDir, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24611") })
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
            if case .segmentUnprovable = $0 { return true }
            return false
        } == false)
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 0)
        try Data(#"{"key":"changed after media offload"}"#.utf8).write(to: metaURL)
        let recreated = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24611") })
        await configure(recreated)
        let changedEvents = ProgressCollector()
        let changedListener = Task {
            for await event in await recreated.progressStream { changedEvents.append(event) }
        }
        defer { changedListener.cancel() }
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        await recreated.sync()
        await recreated.sync()
        await changedEvents.waitForSegmentUnprovable()
        #expect(changedEvents.allEvents.contains { if case .segmentUnprovable = $0 { return true }; return false })
        #expect(!store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath })
        #expect(try Data(contentsOf: metaURL) == Data(#"{"key":"changed after media offload"}"#.utf8))
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
        let previousBytes = try Data(contentsOf: receiptURL)
        try Data((malformed ? "{" : #"{"updated":true}"#).utf8).write(to: segment.url.appendingPathComponent("120000_300_meta.json"))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(key: "120000_300", filename: file.lastPathComponent, sha: sha, size: 5))
        // Even a 200 with the old metadata does not acknowledge this update.
        store.registerRoute(path: IngestProtocolV3.uploadPath, body: uploadResponseJSON())
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24731") })
        await configure(service, cacheRetentionDays: 0)
        await service.sync()
        #expect(try Data(contentsOf: file) == Data("audio".utf8))
        #expect(try Data(contentsOf: receiptURL) == previousBytes)
        // A validate rejection is segment-scoped and not retried inside the pass;
        // the receipt on disk is never replaced by a non-answer.
        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == (malformed ? 0 : 1))
    }

    @Test func duplicateWrittenNameSurvivesServiceRecreationAndEnablesCleanup() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-duplicate-written-name")
        let segment = try makeSegment(root: root, date: Date().addingTimeInterval(-172800))
        let day = dayString(for: segment.date)
        let file = segment.url.appendingPathComponent("120000_300_audio.m4a")
        let sha = try sha256(of: file)
        store.enqueue(body: uploadResponseJSON(status: .duplicate, stored: "115959_300"))
        let first = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24732") })
        await configure(first)
        await first.sync()
        let receiptURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        store.reset()
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(key: "115959_300", filename: "115959_300_audio.m4a", sha: sha, size: 5))
        let second = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24732") })
        await configure(second, cacheRetentionDays: 0)
        await second.sync()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: segment.url.path))
        #expect(!store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath })
    }

    @Test func journalSwitchDuringCleanupReadRetainsMedia() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-cleanup-context-switch")
        let segment = try makeSegment(root: root, date: Date().addingTimeInterval(-172800))
        let day = dayString(for: segment.date)
        let file = segment.url.appendingPathComponent("120000_300_audio.m4a")
        let sha = try sha256(of: file)
        let receipt = IngestAcknowledgment(journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day, submittedSegment: "120000_300", storedSegmentKey: "120000_300", status: .ok,
            payload: .init(files: [.init(submitted: file.lastPathComponent, sha256: sha, size: 5)], meta: [:]))
        try IngestAcknowledgmentStore.write(receipt, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300"))
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: segmentsDayJSON(key: "120000_300", filename: file.lastPathComponent, sha: sha, size: 5))
        let resolver = ResolverScript([.url("http://127.0.0.1:24733")], parkAfterImmediateCount: 0)
        let service = makeService(root: root, resolver: resolver.resolver)
        await configure(service, cacheRetentionDays: 0)
        let syncing = Task { await service.sync() }
        await resolver.waitUntilParked()
        await configureB(service, cacheRetentionDays: 0)
        await resolver.releasePark()
        await syncing.value
        #expect(try Data(contentsOf: file) == Data("audio".utf8))
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
        let receipt = try #require(IngestAcknowledgmentStore.read(from: receiptURL))
        #expect(receipt.payload.files.first?.sha256 == "6ed8919ce20490a5e3ad8630a4fab69475297abd07db73918dd5f36fcfaeb11b")
        #expect(try Data(contentsOf: file) == Data("other".utf8))
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
    func cleanupReadsPastDayOnlyWhenAgeRequiresCleanup() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-cleanup-age")
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 20
        components.hour = 12
        let fixedNow = try #require(calendar.date(from: components))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: fixedNow))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))

        let segRecent = try makeSegment(root: root, date: yesterday, segmentName: "120000_300")
        let segOld = try makeSegment(root: root, date: oldDay, segmentName: "120000_300")

        let filename = "120000_300_audio.m4a"
        let shaRecent = try sha256(of: segRecent.url.appendingPathComponent(filename))
        let shaOld = try sha256(of: segOld.url.appendingPathComponent(filename))

        let ackRecent = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: yesterday),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: shaRecent, size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ackRecent, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segRecent.url, segment: "120000_300"))

        let ackOld = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: oldDay),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: shaOld, size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ackOld, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segOld.url, segment: "120000_300"))

        let todayStr = dayString(for: fixedNow)
        let oldDayStr = dayString(for: oldDay)
        let recentDayStr = dayString(for: yesterday)

        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(entries: [("120000_300", nil, filename, shaOld, 5, "present")]))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24737") }, now: { fixedNow })
        await configure(service, cacheRetentionDays: 7)
        await service.sync()

        let requests = store.snapshotRequests()
        let paths = requests.compactMap { $0.url?.path }
        #expect(paths.contains(IngestProtocolV3.segmentsDayPath(todayStr)))
        #expect(paths.contains(IngestProtocolV3.segmentsDayPath(oldDayStr)))
        #expect(!paths.contains(IngestProtocolV3.segmentsDayPath(recentDayStr)))

        #expect(FileManager.default.fileExists(atPath: segRecent.url.appendingPathComponent(filename).path))
        #expect(!FileManager.default.fileExists(atPath: segOld.url.appendingPathComponent(filename).path))
    }

    @Test
    func cleanupWithRetentionZeroReadsTodayDuringCleanup() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-retention-zero")
        let todayDate = Date()
        let seg = try makeSegment(root: root, date: todayDate, segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        let todayStr = dayString(for: todayDate)

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: todayStr,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)],
                meta: [:]
            )
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: [("120000_300", nil, filename, sha, 5, "present")]))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24738") }, now: { todayDate })
        await configure(service, cacheRetentionDays: 0)
        await service.sync()

        #expect(!FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        #expect(FileManager.default.fileExists(atPath: seg.url.path))
    }

    @Test
    func segmentKeptEmitsProgressEventAndRecordsEvidence() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-kept-reasons")
        let todayDate = Date()
        let todayStr = dayString(for: todayDate)
        let seg = try makeSegment(root: root, date: todayDate, segmentName: "120000_300")
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: todayStr,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)],
                meta: [:]
            )
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        // Case 1: unproven custody (missing on server)
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: [("120000_300", nil, filename, sha, 5, "missing")]))
        let progress1 = ProgressCollector()
        let service1 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24739") }, now: { todayDate })
        await configure(service1, cacheRetentionDays: 0)
        let listen1 = Task {
            for await event in await service1.progressStream { progress1.append(event) }
        }
        await service1.sync()
        await progress1.waitForSyncComplete()
        listen1.cancel()
        #expect(progress1.allEvents.contains {
            if case .segmentKept(let reason) = $0 { return reason == .unproven }
            return false
        })

        // Case 2: listing failed
        store.reset()
        let todayPath = IngestProtocolV3.segmentsDayPath(todayStr)
        store.registerRoute(path: todayPath, statusCode: 500, body: "{}")
        let progress2 = ProgressCollector()
        let service2 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24739") }, now: { todayDate })
        await configure(service2, cacheRetentionDays: 0)
        let listen2 = Task {
            for await event in await service2.progressStream { progress2.append(event) }
        }
        await service2.sync()
        await progress2.waitForOffline()
        listen2.cancel()

        // Case 3: segment removed (empty server items)
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
        let progress3 = ProgressCollector()
        let service3 = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24739") }, now: { todayDate })
        await configure(service3, cacheRetentionDays: 0)
        let listen3 = Task {
            for await event in await service3.progressStream { progress3.append(event) }
        }
        await service3.sync()
        await progress3.waitForSyncComplete()
        listen3.cancel()
        #expect(progress3.allEvents.contains {
            if case .segmentKept(let reason) = $0 { return reason == .unproven }
            return false
        })
    }

    @Test
    func idleAllSegmentsAckedNothingPastRetentionProbesToday() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-idle-all-acked")
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: fixedNow))
        let seg = try makeSegment(root: root, date: yesterday)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: yesterday),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)], meta: [:])
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

        let todayStr = dayString(for: fixedNow)
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24750") }, now: { fixedNow })
        await configure(service, cacheRetentionDays: 7)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForSyncComplete()
        listen.cancel()

        let requests = store.snapshotRequests()
        #expect(requests.compactMap { $0.url?.path } == [IngestProtocolV3.segmentsDayPath(todayStr)])
        #expect(progress.allEvents.contains { if case .journalContactSucceeded = $0 { return true }; return false })
        #expect(progress.containsSyncComplete)
    }

    @Test
    func idleOneUnackedSegmentUploadsAndYieldsContact() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-idle-one-unacked")
        let seg = try makeSegment(root: root)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))

        let progress = ProgressCollector()
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24751") })
        await configure(service)
        let listen = Task {
            for await event in await service.progressStream { progress.append(event) }
        }
        await service.sync()
        await progress.waitForSyncComplete()
        listen.cancel()

        let requests = store.snapshotRequests()
        #expect(requests.compactMap { $0.url?.path } == [IngestProtocolV3.uploadPath])
        #expect(progress.containsUploadSucceeded)
        #expect(progress.allEvents.contains { if case .journalContactSucceeded = $0 { return true }; return false })
        #expect(progress.containsSyncComplete)
    }

    @Test
    func idleRetentionZeroTodayAckedMediaReadOnceAndDeleted() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-retention-zero-today")
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let seg = try makeSegment(root: root, date: fixedNow)
        let filename = "120000_300_audio.m4a"
        let sha = try sha256(of: seg.url.appendingPathComponent(filename))
        let todayStr = dayString(for: fixedNow)

        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: todayStr,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)], meta: [:])
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: sha, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24752") }, now: { fixedNow })
        await configure(service, cacheRetentionDays: 0)
        await service.sync()

        let requests = store.snapshotRequests()
        #expect(requests.compactMap { $0.url?.path } == [IngestProtocolV3.segmentsDayPath(todayStr)])
        #expect(!FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
    }

    @Test
    func idleTwoPastRetentionDaysWithDeletableMediaReadsInOrder() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-two-past-retention")
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let dayOld = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let dayNewer = try #require(calendar.date(byAdding: .day, value: -5, to: fixedNow))

        let segOld = try makeSegment(root: root, date: dayOld)
        let segNewer = try makeSegment(root: root, date: dayNewer)
        let filename = "120000_300_audio.m4a"
        let shaOld = try sha256(of: segOld.url.appendingPathComponent(filename))
        let shaNewer = try sha256(of: segNewer.url.appendingPathComponent(filename))

        let ackOld = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: dayOld),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: shaOld, size: 5)], meta: [:])
        )
        try IngestAcknowledgmentStore.write(ackOld, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segOld.url, segment: "120000_300"))

        let ackNewer = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: dayNewer),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: shaNewer, size: 5)], meta: [:])
        )
        try IngestAcknowledgmentStore.write(ackNewer, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segNewer.url, segment: "120000_300"))

        let todayStr = dayString(for: fixedNow)
        let oldStr = dayString(for: dayOld)
        let newerStr = dayString(for: dayNewer)

        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: shaOld, size: 5))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(newerStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: shaNewer, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24753") }, now: { fixedNow })
        await configure(service, cacheRetentionDays: 2)
        await service.sync()

        let requests = store.snapshotRequests()
        #expect(requests.compactMap { $0.url?.path } == [
            IngestProtocolV3.segmentsDayPath(todayStr),
            IngestProtocolV3.segmentsDayPath(oldStr),
            IngestProtocolV3.segmentsDayPath(newerStr),
        ])
        #expect(!FileManager.default.fileExists(atPath: segOld.url.appendingPathComponent(filename).path))
        #expect(!FileManager.default.fileExists(atPath: segNewer.url.appendingPathComponent(filename).path))
    }

    @Test
    func idlePastRetentionDayWithMediaAlreadyGoneHasZeroReadsAcrossThreePasses() async throws {
        store.reset()
        let root = try makeTempDirectory("sync-media-gone")
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let segDir = root
            .appendingPathComponent(dateFolderString(for: oldDay), isDirectory: true)
            .appendingPathComponent("120000_300", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: dayString(for: oldDay),
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: "120000_300_audio.m4a", sha256: String(repeating: "a", count: 64), size: 5)], meta: [:])
        )
        try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segDir, segment: "120000_300"))

        let todayStr = dayString(for: fixedNow)
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24754") }, now: { fixedNow })
        await configure(service, cacheRetentionDays: 2)

        for _ in 1...3 {
            await service.sync()
        }

        let requests = store.snapshotRequests()
        #expect(requests.compactMap { $0.url?.path } == [
            IngestProtocolV3.segmentsDayPath(todayStr),
            IngestProtocolV3.segmentsDayPath(todayStr),
            IngestProtocolV3.segmentsDayPath(todayStr),
        ])
    }

    @Test
    func cleanupProofKeyMissingVsKeyPresentTwin() async throws {
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let todayStr = dayString(for: fixedNow)
        let oldDayStr = dayString(for: oldDay)
        let filename = "120000_300_audio.m4a"

        // Keep twin: listing has no item whose key is storedSegmentKey
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-a-keep")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)], meta: [:])
            )
            let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300")
            try IngestAcknowledgmentStore.write(ack, to: ackURL)
            let ackBytesBefore = try Data(contentsOf: ackURL)

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(entries: []))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24755") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
            #expect(try Data(contentsOf: ackURL) == ackBytesBefore)

            // Second pass inside 24 h does not GET old day again
            store.reset()
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            await service.sync()
            #expect(store.snapshotRequests().compactMap { $0.url?.path } == [IngestProtocolV3.segmentsDayPath(todayStr)])
        }

        // Positive twin: key is present and file proves hold
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-a-delete")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: sha, size: 5))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24755") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(!FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        }
    }

    @Test
    func cleanupProofSHADiffersVsMatchesTwin() async throws {
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let todayStr = dayString(for: fixedNow)
        let oldDayStr = dayString(for: oldDay)
        let filename = "120000_300_audio.m4a"

        // Keep twin: listing sha256 differs
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-b-keep")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: "0000000000000000000000000000000000000000000000000000000000000000", size: 5))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24756") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        }

        // Positive twin: sha matches
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-b-delete")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: sha, size: 5))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24756") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(!FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        }
    }

    @Test
    func cleanupProofLocalVersionMatchesAndListingSHACheck() async throws {
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let todayStr = dayString(for: fixedNow)
        let oldDayStr = dayString(for: oldDay)
        let filename = "120000_300_audio.m4a"

        // Keep: localVersion equals current stat, but listing sha differs from file
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-c-keep")
            let seg = try makeSegment(root: root, date: oldDay)
            let fileURL = seg.url.appendingPathComponent(filename)
            let sha = try sha256(of: fileURL)
            let localVer = IngestLocalFileVersion.read(fileURL)
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5, localVersion: localVer)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: "badsha", size: 5))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24757") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }

        // Positive twin: listing sha equals hash -> deleted
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-c-delete")
            let seg = try makeSegment(root: root, date: oldDay)
            let fileURL = seg.url.appendingPathComponent(filename)
            let sha = try sha256(of: fileURL)
            let localVer = IngestLocalFileVersion.read(fileURL)
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5, localVersion: localVer)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: sha, size: 5))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24757") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test
    func cleanupProofPastDayReadFailures() async throws {
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let todayStr = dayString(for: fixedNow)
        let oldDayStr = dayString(for: oldDay)
        let filename = "120000_300_audio.m4a"

        // 500 journal_read_failed: throttled for 24h
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-d-500")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), statusCode: 500, body: "{\"status\":\"failed\",\"reason_code\":\"journal_read_failed\"}")

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24758") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))

            // Second pass inside 24 h does not GET old day again
            store.reset()
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            await service.sync()
            #expect(store.snapshotRequests().compactMap { $0.url?.path } == [IngestProtocolV3.segmentsDayPath(todayStr)])
        }

        // URLError on that day records no throttle
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-d-urlerror")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), statusCode: 0, error: URLError(.networkConnectionLost))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24758") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))

            // Next pass reads old day again
            store.reset()
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: sha, size: 5))
            await service.sync()
            let paths = store.snapshotRequests().compactMap { $0.url?.path }
            #expect(paths.contains(IngestProtocolV3.segmentsDayPath(oldDayStr)))
            #expect(!FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        }
    }

    @Test
    func cleanupProofDispositionReceivedNotWrittenVsWrittenTwin() async throws {
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let todayStr = dayString(for: fixedNow)
        let oldDayStr = dayString(for: oldDay)
        let filename = "120000_300_audio.m4a"

        // Keep: disposition receivedNotWritten
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-e-rnw")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5, disposition: .receivedNotWritten)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: sha, size: 5))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24759") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        }

        // Delete: disposition written
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-e-written")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5, disposition: .written)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(key: "120000_300", filename: filename, sha: sha, size: 5))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24759") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(!FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        }
    }

    @Test
    func cleanupProofStatusMissingAndArchivedVsPresent() async throws {
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let todayStr = dayString(for: fixedNow)
        let oldDayStr = dayString(for: oldDay)
        let filename = "120000_300_audio.m4a"

        for status in ["missing", "archived"] {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-f-\(status)")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: [(oldDayStr, nil, filename, sha, 5, status)]))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(entries: [("120000_300", nil, filename, sha, 5, status)]))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24760") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        }
    }

    @Test
    func cleanupProofDistinctNameAndSubmittedNameTwin() async throws {
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let todayStr = dayString(for: fixedNow)
        let oldDayStr = dayString(for: oldDay)
        let filename = "120000_300_audio.m4a"

        // Keep: name != proof.written while submitted_name == proof.written
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-g-keep")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5, written: filename)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(detailedEntries: [(key: "120000_300", originalKey: nil, name: "other_audio.m4a", submittedName: filename, sha: sha, size: 5, status: "present")]))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24761") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        }

        // Delete: name == proof.written and submitted_name is different
        do {
            store.reset()
            let root = try makeTempDirectory("sync-cleanup-proof-g-delete")
            let seg = try makeSegment(root: root, date: oldDay)
            let sha = try sha256(of: seg.url.appendingPathComponent(filename))
            let ack = IngestAcknowledgment(
                journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
                day: oldDayStr,
                submittedSegment: "120000_300",
                storedSegmentKey: "120000_300",
                status: .ok,
                payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5, written: filename)], meta: [:])
            )
            try IngestAcknowledgmentStore.write(ack, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: seg.url, segment: "120000_300"))

            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
            store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(detailedEntries: [(key: "120000_300", originalKey: nil, name: filename, submittedName: "other_audio.m4a", sha: sha, size: 5, status: "present")]))

            let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24761") }, now: { fixedNow })
            await configure(service, cacheRetentionDays: 2)
            await service.sync()

            #expect(!FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))
        }
    }

    @Test
    func cleanupProofThrottledSegmentDoesNotBlockNewSegmentOnSameDay() async throws {
        let calendar = IngestDayKey.calendar
        let fixedNow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let oldDay = try #require(calendar.date(byAdding: .day, value: -10, to: fixedNow))
        let todayStr = dayString(for: fixedNow)
        let oldDayStr = dayString(for: oldDay)

        store.reset()
        let root = try makeTempDirectory("sync-cleanup-proof-h")
        let segA = try makeSegment(root: root, date: oldDay, segmentName: "120000_300")
        let fileA = "120000_300_audio.m4a"
        let shaA = try sha256(of: segA.url.appendingPathComponent(fileA))

        let ackA = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: oldDayStr,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: fileA, sha256: shaA, size: 5)], meta: [:])
        )
        let ackAURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segA.url, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ackA, to: ackAURL)
        let ackABytesBefore = try Data(contentsOf: ackAURL)

        // Pass 1: segA is unproven on server (missing)
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(entries: [("120000_300", nil, fileA, shaA, 5, "missing")]))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24762") }, now: { fixedNow })
        await configure(service, cacheRetentionDays: 2)
        await service.sync()

        #expect(FileManager.default.fileExists(atPath: segA.url.appendingPathComponent(fileA).path))

        // Create acked segment B on the same day
        let segB = try makeSegment(root: root, date: oldDay, segmentName: "120500_300")
        let fileB = "120500_300_audio.m4a"
        let shaB = try sha256(of: segB.url.appendingPathComponent(fileB))
        let ackB = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: oldDayStr,
            submittedSegment: "120500_300",
            storedSegmentKey: "120500_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(files: [IngestAcknowledgedFileProof(submitted: fileB, sha256: shaB, size: 5)], meta: [:])
        )
        try IngestAcknowledgmentStore.write(ackB, to: IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segB.url, segment: "120500_300"))

        // Pass 2: segB is proven
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(todayStr), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(oldDayStr), body: segmentsDayJSON(entries: [
            ("120000_300", nil, fileA, shaA, 5, "missing"),
            ("120500_300", nil, fileB, shaB, 5, "present")
        ]))

        await service.sync()

        #expect(FileManager.default.fileExists(atPath: segA.url.appendingPathComponent(fileA).path))
        #expect(try Data(contentsOf: ackAURL) == ackABytesBefore)
        #expect(!FileManager.default.fileExists(atPath: segB.url.appendingPathComponent(fileB).path))
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

        #expect(FileManager.default.fileExists(atPath: seg.url.appendingPathComponent(filename).path))

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
        _ = try makeSegment(root: root)
        store.registerRoute(path: IngestProtocolV3.uploadPath, statusCode: 500, body: "{\"reason_code\":\"journal_write_failed\"}")
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24765") })
        await configure(service)
        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
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

        // Configure with same pairing & different retention does NOT clear quiet hour
        store.reset()
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        await configure(service, cacheRetentionDays: 14)
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
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath("20260915"), body: segmentsDayJSON(key: "120000_300", filename: "120000_300_audio.m4a", sha: proof.sha256, size: 5))

        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24744") }, now: { fixedNow })
        await configure(service, cacheRetentionDays: 1)
        await service.sync()

        let requests = store.snapshotRequests()
        let paths = requests.compactMap { $0.url?.path }
        #expect(paths == [IngestProtocolV3.segmentsDayPath("20260917"), IngestProtocolV3.segmentsDayPath("20260915")])
        #expect(!FileManager.default.fileExists(atPath: mediaURL.path))
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

    private func assertMalformedSegmentsDayFailsClosed(
        root: URL,
        segment: (url: URL, date: Date),
        day: String,
        filename: String,
        sha: String,
        malformedSegmentsDay: String
    ) async throws {
        let ack = IngestAcknowledgment(
            journalFingerprint: tunnelJournalConnectionFingerprint(for: pairingA).value,
            day: day,
            submittedSegment: "120000_300",
            storedSegmentKey: "120000_300",
            status: .ok,
            payload: IngestAcknowledgmentPayload(
                files: [IngestAcknowledgedFileProof(submitted: filename, sha256: sha, size: 5)],
                meta: [:]
            )
        )
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segment.url, segment: "120000_300")
        try IngestAcknowledgmentStore.write(ack, to: ackURL)

        store.reset()
        let today = IngestDayKey.string(from: Date())
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(today), body: segmentsDayJSON(entries: []))
        store.registerRoute(path: IngestProtocolV3.segmentsDayPath(day), body: malformedSegmentsDay)
        let service = makeService(root: root, resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24689") })
        await configure(service, cacheRetentionDays: 0)

        await service.sync()

        #expect(FileManager.default.fileExists(atPath: segment.url.appendingPathComponent(filename).path))
        #expect(store.snapshotRequests().contains { $0.url?.path == IngestProtocolV3.uploadPath } == false)

        try FileManager.default.removeItem(at: ackURL)
        store.reset()
        store.enqueue(statusCode: 200, body: uploadResponseJSON(filename: filename, sha: sha, size: 5))
        await service.sync()

        #expect(store.snapshotRequests().filter { $0.url?.path == IngestProtocolV3.uploadPath }.count == 1)
        #expect(FileManager.default.fileExists(atPath: segment.url.path))
    }

    private func makeService(
        root: URL,
        resolver: HomeBaseURLResolver,
        now: (@escaping @Sendable () -> Date) = Date.init,
        listDirectory: (@Sendable (URL) throws -> [URL])? = nil,
        classifyEntry: (@Sendable (URL) throws -> SyncService.DiscoveredEntryKind)? = nil
    ) -> SyncService {
        if let listDirectory, let classifyEntry {
            return SyncService(
                storageManager: StorageManager(baseDirectory: root),
                client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
                resolver: resolver,
                now: now,
                retryDelays: Array(repeating: 0, count: 10),
                listDirectory: listDirectory,
                classifyEntry: classifyEntry
            )
        } else if let listDirectory {
            return SyncService(
                storageManager: StorageManager(baseDirectory: root),
                client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
                resolver: resolver,
                now: now,
                retryDelays: Array(repeating: 0, count: 10),
                listDirectory: listDirectory
            )
        } else if let classifyEntry {
            return SyncService(
                storageManager: StorageManager(baseDirectory: root),
                client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
                resolver: resolver,
                now: now,
                retryDelays: Array(repeating: 0, count: 10),
                classifyEntry: classifyEntry
            )
        } else {
            return SyncService(
                storageManager: StorageManager(baseDirectory: root),
                client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
                resolver: resolver,
                now: now,
                retryDelays: Array(repeating: 0, count: 10)
            )
        }
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
