// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Darwin
import Foundation
import Testing
import WebKit
@testable import solstone

/// Minimal real loopback HTTP/1.1 server for testing native export downloads,
/// Range + If-Range resume, mid-stream drop, and 410 Trash-erasure invalidation.
private final class LocalExportServer: @unchecked Sendable {
    enum Mode {
        case ok
        case dropFirstAfter(Int)
        case goneErased
        case mismatchIfRangeTo200
        case corruptBodyByte
        case bogus206WrongETagAfter(Int)
    }

    private let payload: Data
    private let etag: String
    private let lock = NSLock()
    private var mode: Mode
    private var requestCount = 0
    private var receivedRanges: [String] = []
    private var listenFD: Int32 = -1
    private var stopped = false
    let port: UInt16

    init(payload: Data, etag: String, mode: Mode = .ok) throws {
        self.payload = payload
        self.etag = etag
        self.mode = mode

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func recordedRanges() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return receivedRanges
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    deinit { stop() }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let isStopped = stopped
            lock.unlock()
            if isStopped || fd < 0 { return }
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { Darwin.close(client) }
                self?.serve(client: client)
            }
        }
    }

    private func serve(client: Int32) {
        var reqBuf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while !reqBuf.contains(Data("\r\n\r\n".utf8)) && reqBuf.count < 16384 {
            let n = Darwin.recv(client, &tmp, tmp.count, 0)
            if n <= 0 { return }
            reqBuf.append(contentsOf: tmp[..<n])
        }
        let headerText = String(decoding: reqBuf, as: UTF8.self)
        var rangeHeader: String?
        var ifRangeHeader: String?
        for line in headerText.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "range" { rangeHeader = val }
            if key == "if-range" { ifRangeHeader = val }
        }

        lock.lock()
        requestCount += 1
        let attempt = requestCount
        if let rangeHeader { receivedRanges.append(rangeHeader) }
        let currentMode = mode
        lock.unlock()

        switch currentMode {
        case .goneErased:
            let body = Data(#"{"code":"export_invalidated_by_erasure"}"#.utf8)
            let head = "HTTP/1.1 410 Gone\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            sendAll(client, Data(head.utf8))
            sendAll(client, body)
        case .dropFirstAfter(let cut) where attempt == 1:
            let slice = payload.prefix(cut)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nETag: \(etag)\r\nAccept-Ranges: bytes\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            sendAll(client, Data(head.utf8))
            sendAll(client, slice)
        case .bogus206WrongETagAfter(let cut):
            if attempt == 1 {
                let slice = payload.prefix(cut)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nETag: \(etag)\r\nAccept-Ranges: bytes\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                sendAll(client, Data(head.utf8))
                sendAll(client, slice)
            } else {
                let end = payload.count - 1
                let slice = payload[cut...end]
                let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: application/zip\r\nETag: \"mismatched-etag\"\r\nAccept-Ranges: bytes\r\nContent-Range: bytes \(cut)-\(end)/\(payload.count)\r\nContent-Length: \(slice.count)\r\nConnection: close\r\n\r\n"
                sendAll(client, Data(head.utf8))
                sendAll(client, Data(slice))
            }
        case .mismatchIfRangeTo200:
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nETag: \(etag)\r\nAccept-Ranges: bytes\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            sendAll(client, Data(head.utf8))
            sendAll(client, payload)
        case .corruptBodyByte:
            var bad = payload
            if !bad.isEmpty { bad[0] ^= 0xFF }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nETag: \(etag)\r\nAccept-Ranges: bytes\r\nContent-Length: \(bad.count)\r\nConnection: close\r\n\r\n"
            sendAll(client, Data(head.utf8))
            sendAll(client, bad)
        default:
            if let rangeHeader, rangeHeader.hasPrefix("bytes="),
               ifRangeHeader == nil || ifRangeHeader == etag {
                let spec = rangeHeader.dropFirst(6)
                let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
                if let start = Int(bounds[0]), start >= 0, start < payload.count {
                    let end = payload.count - 1
                    let slice = payload[start...end]
                    let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: application/zip\r\nETag: \(etag)\r\nAccept-Ranges: bytes\r\nContent-Range: bytes \(start)-\(end)/\(payload.count)\r\nContent-Length: \(slice.count)\r\nConnection: close\r\n\r\n"
                    sendAll(client, Data(head.utf8))
                    sendAll(client, Data(slice))
                    return
                }
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nETag: \(etag)\r\nAccept-Ranges: bytes\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            sendAll(client, Data(head.utf8))
            sendAll(client, payload)
        }
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@MainActor
private final class NoOpExportImportIntake: JournalImportIntake {
    func addHandedOver(_ urls: [URL], handoff: ImportHandoff) async -> ImportAddResult {
        ImportAddResult(outcomes: [])
    }
    func handoffStatus(_ id: String) async -> ImportHandoffStatus { .gone }
}

@MainActor
struct JournalExportHostTests {
    private func waitForPhase(
        _ manager: JournalExportTransferManager,
        target: Set<String>,
        timeoutSeconds: Double = 10
    ) async -> JournalExportStatusSnapshot {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if target.contains(manager.snapshot.phase) { return manager.snapshot }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return manager.snapshot
    }

    @Test func contractLoadsFromBundleAndAdvertisesExportTypesInUserScript() throws {
        let exportContract = try #require(JournalExportContract.packaged())
        #expect(exportContract.version == 2)
        #expect(exportContract.capability == "solstoneJournalHost")
        #expect(exportContract.start == "export.start")
        #expect(exportContract.deviceSpace == "export.device_space")
        #expect(exportContract.event == "solstone-journal-export-status")

        let importContract = try #require(JournalImportContract.packaged())
        let manager = JournalExportTransferManager(prepareRequest: { _ in })
        let baseURL = URL(string: "http://127.0.0.1:41234")!
        let exportHost = JournalExportHost(
            contract: exportContract,
            manager: manager,
            liveBaseURL: { baseURL },
            transportKind: { "local" }
        )
        let host = JournalImportHost(
            contract: importContract,
            authHost: nil,
            exportHost: exportHost,
            intake: { NoOpExportImportIntake() },
            liveBaseURL: { baseURL }
        )
        let script = try #require(host.userScript(for: baseURL))
        #expect(script.source.contains("export.start"))
        #expect(script.source.contains("export.device_space"))
        #expect(script.source.contains("solstone-journal-export-status"))
    }

    @Test func nativeSaveStreamsVerifiesSHA256AndRevealsFile() async throws {
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 & 0xFF) })
        let sha = sha256Hex(payload)
        let etag = "\"\(sha)\""
        let server = try LocalExportServer(payload: payload, etag: etag)
        defer { server.stop() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("solstone-journal-2026-11-26.zip")

        var revealedURL: URL?
        let manager = JournalExportTransferManager(
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 10 * 1024 * 1024 * 1024 },
            revealFile: { revealedURL = $0 }
        )
        let contract = try #require(JournalExportContract.packaged())
        let exportHost = JournalExportHost(
            contract: contract,
            manager: manager,
            liveBaseURL: { server.baseURL },
            transportKind: { "local" },
            presentSavePanel: { _, _ in dest }
        )

        _ = await exportHost.handle([
            "id": "r1",
            "export_id": "exp_ok_1",
            "download_path": "/app/export/api/ready/exp_ok_1/download",
            "filename": "solstone-journal-2026-11-26.zip",
            "size_bytes": payload.count,
            "sha256": sha,
            "etag": etag,
            "mode": "full",
        ], type: contract.start)

        let done = await waitForPhase(manager, target: ["saved", "error"])
        #expect(done.phase == "saved")
        #expect(done.verified == true)
        #expect(done.canReveal == true)
        #expect(try Data(contentsOf: dest) == payload)
        #expect(!FileManager.default.fileExists(atPath: JournalExportTransferManager.partURL(for: dest, exportID: "exp_ok_1").path))

        let perms = (try FileManager.default.attributesOfItem(atPath: dest.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)

        let revealReply = await exportHost.handle(["id": "r2", "export_id": "exp_ok_1"], type: contract.reveal)
        #expect(revealReply["revealed"] as? Bool == true)
        #expect(revealedURL == dest)
    }

    @Test func interruptedDownloadResumesWithRangeAndVerifies() async throws {
        let payload = Data((0..<(300 * 1024)).map { UInt8(($0 * 7) & 0xFF) })
        let sha = sha256Hex(payload)
        let etag = "\"\(sha)\""
        let server = try LocalExportServer(payload: payload, etag: etag, mode: .dropFirstAfter(100 * 1024))
        defer { server.stop() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-res-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("resumed.zip")

        let manager = JournalExportTransferManager(
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 10 * 1024 * 1024 * 1024 }
        )
        let contract = try #require(JournalExportContract.packaged())
        let exportHost = JournalExportHost(
            contract: contract,
            manager: manager,
            liveBaseURL: { server.baseURL },
            transportKind: { "local" },
            presentSavePanel: { _, _ in dest }
        )

        _ = await exportHost.handle([
            "id": "r1",
            "export_id": "exp_res_1",
            "download_path": "/app/export/api/ready/exp_res_1/download",
            "filename": "resumed.zip",
            "size_bytes": payload.count,
            "sha256": sha,
            "etag": etag,
        ], type: contract.start)

        let paused = await waitForPhase(manager, target: ["paused", "error", "saved"])
        #expect(paused.phase == "paused")
        #expect(paused.pauseReason == "disconnected")
        #expect(paused.bytesWritten == 100 * 1024)

        _ = await exportHost.handle(["id": "r2", "export_id": "exp_res_1"], type: contract.resume)
        let done = await waitForPhase(manager, target: ["saved", "error"])
        #expect(done.phase == "saved")
        #expect(server.recordedRanges() == ["bytes=102400-"])
        #expect(try Data(contentsOf: dest) == payload)
    }

    @Test func checksumMismatchAndInsufficientSpacePreserveExistingDestination() async throws {
        let payload = Data(repeating: 0x42, count: 64 * 1024)
        let sha = sha256Hex(payload)
        let etag = "\"\(sha)\""
        let server = try LocalExportServer(payload: payload, etag: etag, mode: .corruptBodyByte)
        defer { server.stop() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("existing.zip")
        let sentinel = Data("preexisting-owner-file".utf8)
        try sentinel.write(to: dest)

        // 1. Insufficient destination volume space refuses before touching disk.
        let tightManager = JournalExportTransferManager(
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 1024 }
        )
        let contract = try #require(JournalExportContract.packaged())
        let tightHost = JournalExportHost(
            contract: contract,
            manager: tightManager,
            liveBaseURL: { server.baseURL },
            presentSavePanel: { _, _ in dest }
        )
        let tightReply = await tightHost.handle([
            "id": "r1",
            "export_id": "exp_space_1",
            "download_path": "/app/export/api/ready/exp_space_1/download",
            "filename": "existing.zip",
            "size_bytes": payload.count,
            "sha256": sha,
            "etag": etag,
        ], type: contract.start)
        #expect(tightReply["phase"] as? String == "error")
        #expect(tightReply["error_code"] as? String == "insufficient_device_space")
        #expect(try Data(contentsOf: dest) == sentinel)

        // 2. Checksum mismatch deletes partial and leaves preexisting destination untouched.
        let badManager = JournalExportTransferManager(
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 10 * 1024 * 1024 * 1024 }
        )
        let badHost = JournalExportHost(
            contract: contract,
            manager: badManager,
            liveBaseURL: { server.baseURL },
            presentSavePanel: { _, _ in dest }
        )
        _ = await badHost.handle([
            "id": "r2",
            "export_id": "exp_bad_1",
            "download_path": "/app/export/api/ready/exp_bad_1/download",
            "filename": "existing.zip",
            "size_bytes": payload.count,
            "sha256": sha,
            "etag": etag,
        ], type: contract.start)
        let badDone = await waitForPhase(badManager, target: ["error", "saved"])
        #expect(badDone.phase == "error")
        #expect(badDone.errorCode == "checksum_mismatch")
        #expect(try Data(contentsOf: dest) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: JournalExportTransferManager.partURL(for: dest, exportID: "exp_bad_1").path))
    }

    @Test func trashErasure410InvalidatesAndCleansPartial() async throws {
        let payload = Data(repeating: 0x33, count: 16 * 1024)
        let sha = sha256Hex(payload)
        let server = try LocalExportServer(payload: payload, etag: "\"\(sha)\"", mode: .goneErased)
        defer { server.stop() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-410-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("erased.zip")

        let manager = JournalExportTransferManager(
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 10 * 1024 * 1024 * 1024 }
        )
        let contract = try #require(JournalExportContract.packaged())
        let exportHost = JournalExportHost(
            contract: contract,
            manager: manager,
            liveBaseURL: { server.baseURL },
            presentSavePanel: { _, _ in dest }
        )
        _ = await exportHost.handle([
            "id": "r1",
            "export_id": "exp_gone_1",
            "download_path": "/app/export/api/ready/exp_gone_1/download",
            "filename": "erased.zip",
            "size_bytes": payload.count,
            "sha256": sha,
            "etag": "\"\(sha)\"",
        ], type: contract.start)
        let done = await waitForPhase(manager, target: ["error", "saved"])
        #expect(done.phase == "error")
        #expect(done.errorCode == "export_invalidated_by_erasure")
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func slowConsumerBoundsURLSessionBufferOn32MiBStream() async throws {
        let totalSize = 32 * 1024 * 1024
        var payload = Data(count: totalSize)
        payload.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<totalSize {
                ptr[i] = UInt8((i &* 31) & 0xFF)
            }
        }
        let expectedSHA = sha256Hex(payload)
        let server = try LocalExportServer(payload: payload, etag: "\"\(expectedSHA)\"")
        defer { server.stop() }

        let delegate = ExportStreamDelegate(highWaterBytes: 2 * 1024 * 1024, lowWaterBytes: 512 * 1024)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let url = server.baseURL.appendingPathComponent("/app/export/api/ready/exp_32m/download")
        let dataTask = session.dataTask(with: URLRequest(url: url))
        let (http, stream) = try await delegate.startAndAwaitResponse(task: dataTask)
        #expect(http.statusCode == 200)

        // Simulate a slow destination writer before and during consumption.
        try await Task.sleep(for: .milliseconds(120))
        var hasher = SHA256()
        var received = 0
        var chunksRead = 0
        while let chunk = try await stream.nextChunk() {
            hasher.update(data: chunk)
            received += chunk.count
            chunksRead += 1
            if chunksRead % 8 == 0 {
                try await Task.sleep(for: .milliseconds(4))
            }
        }
        let actualSHA = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(received == totalSize)
        #expect(actualSHA == expectedSHA)
        #expect(
            delegate.maxBufferedBytes < 6 * 1024 * 1024,
            "Expected bounded receive queue well below 32 MiB; peaked at \(delegate.maxBufferedBytes) bytes"
        )
    }

    @Test func resume206WithMismatchedETagRefusesAppendAndPreservesDestination() async throws {
        let payload = Data((0..<(128 * 1024)).map { UInt8(($0 * 11) & 0xFF) })
        let sha = sha256Hex(payload)
        let etag = "\"\(sha)\""
        let server = try LocalExportServer(payload: payload, etag: etag, mode: .bogus206WrongETagAfter(32 * 1024))
        defer { server.stop() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-etag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("keep.zip")
        let sentinel = Data("keep-untouched".utf8)
        try sentinel.write(to: dest)

        let manager = JournalExportTransferManager(
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 10 * 1024 * 1024 * 1024 }
        )
        let contract = try #require(JournalExportContract.packaged())
        let exportHost = JournalExportHost(
            contract: contract,
            manager: manager,
            liveBaseURL: { server.baseURL },
            transportKind: { "local" },
            presentSavePanel: { _, _ in dest }
        )
        _ = await exportHost.handle([
            "id": "r1",
            "export_id": "exp_etag_1",
            "download_path": "/app/export/api/ready/exp_etag_1/download",
            "filename": "keep.zip",
            "size_bytes": payload.count,
            "sha256": sha,
            "etag": etag,
        ], type: contract.start)

        let paused = await waitForPhase(manager, target: ["paused", "error", "saved"])
        #expect(paused.phase == "paused")

        _ = await exportHost.handle(["id": "r2", "export_id": "exp_etag_1"], type: contract.resume)
        let failed = await waitForPhase(manager, target: ["error", "saved"])
        #expect(failed.phase == "error")
        #expect(failed.errorCode == "checksum_mismatch")
        #expect(try Data(contentsOf: dest) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: JournalExportTransferManager.partURL(for: dest, exportID: "exp_etag_1").path))
    }

    @Test func cancelDuringTransferPreventsStaleAttemptFromPublishing() async throws {
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8(($0 * 13) & 0xFF) })
        let sha = sha256Hex(payload)
        let etag = "\"\(sha)\""
        let server = try LocalExportServer(payload: payload, etag: etag)
        defer { server.stop() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("existing.zip")
        let sentinel = Data("untouched-by-cancel".utf8)
        try sentinel.write(to: dest)

        let manager = JournalExportTransferManager(
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 10 * 1024 * 1024 * 1024 }
        )
        let contract = try #require(JournalExportContract.packaged())
        let exportHost = JournalExportHost(
            contract: contract,
            manager: manager,
            liveBaseURL: { server.baseURL },
            transportKind: { "local" },
            presentSavePanel: { _, _ in dest }
        )
        _ = await exportHost.handle([
            "id": "r1",
            "export_id": "exp_cancel_1",
            "download_path": "/app/export/api/ready/exp_cancel_1/download",
            "filename": "existing.zip",
            "size_bytes": payload.count,
            "sha256": sha,
            "etag": etag,
        ], type: contract.start)
        _ = await exportHost.handle(["id": "r2", "export_id": "exp_cancel_1"], type: contract.cancel)
        try await Task.sleep(for: .milliseconds(250))
        #expect(manager.snapshot.phase == "idle")
        #expect(try Data(contentsOf: dest) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: JournalExportTransferManager.partURL(for: dest, exportID: "exp_cancel_1").path))
    }

    private final class AtomicOffsetBox: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: Int64 = 0
        private var triggered = false

        func record(_ value: Int64) {
            lock.withLock { offset = value }
        }

        func value() -> Int64 {
            lock.withLock { offset }
        }

        func fireOnceAtOrAbove(_ threshold: Int64, offset value: Int64) -> Bool {
            lock.withLock {
                guard !triggered, value >= threshold else { return false }
                triggered = true
                offset = value
                return true
            }
        }
    }

    private static func makeSyntheticData(count: Int, mul: Int, add: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<count {
                ptr[i] = UInt8((i &* mul &+ add) & 0xFF)
            }
        }
        return data
    }

    @Test func sha256CancellationStopsPromptlyAndFreshSaveToSameDestinationSucceeds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-verify-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Direct cooperative cancellation of sha256File on a physically allocated 16 MiB file.
        let bigFile = dir.appendingPathComponent("phys-16m.part")
        let sixteenMiB = 16 * 1024 * 1024
        try Self.makeSyntheticData(count: sixteenMiB, mul: 37, add: 13).write(to: bigFile)

        let directBox = AtomicOffsetBox()
        let cancelFlag = ExportCancellationFlag()
        let directTask = Task.detached { () -> Result<String, Error> in
            do {
                let digest = try JournalExportTransferManager.sha256File(
                    at: bigFile,
                    shouldCancel: { cancelFlag.isCancelled },
                    onChunkRead: { offset in
                        directBox.record(offset)
                        if offset >= 256 * 1024 {
                            cancelFlag.cancel()
                            try? FileManager.default.removeItem(at: bigFile)
                        }
                    }
                )
                return .success(digest)
            } catch {
                return .failure(error)
            }
        }
        let directOutcome = await directTask.value
        switch directOutcome {
        case .success:
            Issue.record("expected CancellationError when cancelled after first 256 KiB")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let observed = directBox.value()
        #expect(observed <= 512 * 1024, "expected verification to stop promptly; read \(observed) bytes of \(sixteenMiB)")

        // 2. Host cancel during verification preserves existing destination and allows a clean fresh save.
        let payload = Self.makeSyntheticData(count: 4 * 1024 * 1024, mul: 19, add: 3)
        let sha = sha256Hex(payload)
        let etag = "\"\(sha)\""
        let server = try LocalExportServer(payload: payload, etag: etag)
        defer { server.stop() }

        let dest = dir.appendingPathComponent("solstone-journal.zip")
        let sentinel = Data("preexisting-archive-untouched".utf8)
        try sentinel.write(to: dest)

        let verifyBox = AtomicOffsetBox()
        let enteredVerify = DispatchSemaphore(value: 0)
        let cancelIssued = DispatchSemaphore(value: 0)
        let manager = JournalExportTransferManager(
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 10 * 1024 * 1024 * 1024 },
            onVerifyChunkRead: { offset in
                if verifyBox.fireOnceAtOrAbove(256 * 1024, offset: offset) {
                    enteredVerify.signal()
                    _ = cancelIssued.wait(timeout: .now() + .seconds(5))
                } else {
                    verifyBox.record(offset)
                }
            }
        )
        let contract = try #require(JournalExportContract.packaged())
        let exportHost = JournalExportHost(
            contract: contract,
            manager: manager,
            liveBaseURL: { server.baseURL },
            transportKind: { "local" },
            presentSavePanel: { _, _ in dest }
        )

        let cancelDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = enteredVerify.wait(timeout: .now() + .seconds(10))
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    _ = manager.cancel(exportID: "exp_vc_1")
                }
            }
            cancelIssued.signal()
            cancelDone.signal()
        }
        defer { cancelIssued.signal() }

        _ = await exportHost.handle([
            "id": "vc-1",
            "export_id": "exp_vc_1",
            "download_path": "/app/export/api/ready/exp_vc_1/download",
            "filename": "solstone-journal.zip",
            "size_bytes": payload.count,
            "sha256": sha,
            "etag": etag,
        ], type: contract.start)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = cancelDone.wait(timeout: .now() + .seconds(10))
                cont.resume()
            }
        }
        let cancelledSnap = await waitForPhase(manager, target: ["idle", "saved", "error"])
        #expect(cancelledSnap.phase == "idle")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Data(contentsOf: dest) == sentinel, "cancelled save must preserve preexisting destination")
        let vcObserved = verifyBox.value()
        #expect(vcObserved == 256 * 1024, "expected verify reader to stop at first 256 KiB chunk, read \(vcObserved)")

        // Fresh save to the exact same destination succeeds and publishes verified bytes.
        _ = await exportHost.handle([
            "id": "vc-2",
            "export_id": "exp_vc_1",
            "download_path": "/app/export/api/ready/exp_vc_1/download",
            "filename": "solstone-journal.zip",
            "size_bytes": payload.count,
            "sha256": sha,
            "etag": etag,
        ], type: contract.start)
        let saved = await waitForPhase(manager, target: ["saved", "error"])
        #expect(saved.phase == "saved")
        #expect(saved.verified == true)
        #expect(try Data(contentsOf: dest) == payload)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".part") } ?? []
        #expect(leftovers.isEmpty, "expected zero leftover .part files, found \(leftovers)")
    }

    @Test func restartCreditsOnDiskPartialFromFirstAndLaterGenerationsUnderTightSpace() async throws {
        let sixteenMiB = 16 * 1024 * 1024
        let twelveMiB = 12 * 1024 * 1024
        let fiveMiB: Int64 = 5 * 1024 * 1024
        var payload = Data(count: sixteenMiB)
        payload.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<sixteenMiB {
                ptr[i] = UInt8((i &* 41 &+ 7) & 0xFF)
            }
        }
        let sha = sha256Hex(payload)
        let etag = "\"\(sha)\""
        let contract = try #require(JournalExportContract.packaged())

        for (caseLabel, exportID, partFilename) in [
            ("first_gen", "exp_restart_mac_g1", ".solstone-export-exp_restart_mac_g1-1.part"),
            ("later_gen", "exp_restart_mac_g2", ".solstone-export-exp_restart_mac_g2-4.part"),
        ] {
            let server = try LocalExportServer(payload: payload, etag: etag)
            defer { server.stop() }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-restart-\(caseLabel)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let dest = dir.appendingPathComponent("solstone-journal.zip")
            let partial = dir.appendingPathComponent(partFilename)
            try payload.prefix(twelveMiB).write(to: partial)

            // 4 MiB free (< 4 MiB remaining + 1 MiB headroom) refuses and keeps the partial intact.
            let tightManager = JournalExportTransferManager(
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 4 * 1024 * 1024 }
            )
            let tightHost = JournalExportHost(
                contract: contract,
                manager: tightManager,
                liveBaseURL: { server.baseURL },
                transportKind: { "local" },
                presentSavePanel: { _, _ in dest }
            )
            let refused = await tightHost.handle([
                "id": "tight-\(caseLabel)",
                "export_id": exportID,
                "download_path": "/app/export/api/ready/\(exportID)/download",
                "filename": "solstone-journal.zip",
                "size_bytes": sixteenMiB,
                "sha256": sha,
                "etag": etag,
            ], type: contract.start)
            #expect(refused["phase"] as? String == "error")
            #expect(refused["error_code"] as? String == "insufficient_device_space")
            #expect(refused["required_bytes"] as? Int64 == fiveMiB)
            #expect(FileManager.default.fileExists(atPath: partial.path))

            // Fresh manager with exactly 5 MiB free credits the 12 MiB partial and resumes via Range + If-Range.
            let freshManager = JournalExportTransferManager(
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in fiveMiB }
            )
            let freshHost = JournalExportHost(
                contract: contract,
                manager: freshManager,
                liveBaseURL: { server.baseURL },
                transportKind: { "local" },
                presentSavePanel: { _, _ in dest }
            )
            _ = await freshHost.handle([
                "id": "resume-\(caseLabel)",
                "export_id": exportID,
                "download_path": "/app/export/api/ready/\(exportID)/download",
                "filename": "solstone-journal.zip",
                "size_bytes": sixteenMiB,
                "sha256": sha,
                "etag": etag,
            ], type: contract.start)

            let saved = await waitForPhase(freshManager, target: ["saved", "error"])
            #expect(saved.phase == "saved", "case \(caseLabel) failed: \(String(describing: saved.errorCode))")
            #expect(saved.verified == true)
            #expect(try Data(contentsOf: dest) == payload)
            #expect(server.recordedRanges().contains("bytes=\(twelveMiB)-"), "case \(caseLabel) must send Range from 12 MiB")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".part") } ?? []
            #expect(leftovers.isEmpty, "case \(caseLabel) left partial files behind: \(leftovers)")
        }
    }

    @Test func fullLengthPartialProbesLiveEligibilityVerifiesLocallyAndRespectsErasure() async throws {
        let size = 4 * 1024 * 1024
        let payload = Self.makeSyntheticData(count: size, mul: 53, add: 11)
        let sha = sha256Hex(payload)
        let etag = "\"\(sha)\""
        let contract = try #require(JournalExportContract.packaged())

        // 1. Live eligible full-length partial (quit during verification): 1-byte Range/If-Range probe,
        //    local SHA-256 verification, publish under 1 MiB headroom (no full refetch).
        do {
            let server = try LocalExportServer(payload: payload, etag: etag)
            defer { server.stop() }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-fullpart-ok-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let dest = dir.appendingPathComponent("solstone-journal.zip")
            let fullPart = dir.appendingPathComponent(".solstone-export-exp_full_mac_1-2.part")
            try payload.write(to: fullPart)

            let manager = JournalExportTransferManager(
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 1 * 1024 * 1024 }
            )
            let host = JournalExportHost(
                contract: contract,
                manager: manager,
                liveBaseURL: { server.baseURL },
                transportKind: { "local" },
                presentSavePanel: { _, _ in dest }
            )
            _ = await host.handle([
                "id": "full-ok",
                "export_id": "exp_full_mac_1",
                "download_path": "/app/export/api/ready/exp_full_mac_1/download",
                "filename": "solstone-journal.zip",
                "size_bytes": size,
                "sha256": sha,
                "etag": etag,
            ], type: contract.start)

            let saved = await waitForPhase(manager, target: ["saved", "error"])
            #expect(saved.phase == "saved")
            #expect(saved.verified == true)
            #expect(try Data(contentsOf: dest) == payload)
            #expect(server.recordedRanges() == ["bytes=\(size - 1)-\(size - 1)"])
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".part") } ?? []
            #expect(leftovers.isEmpty)
        }

        // 2. Full-length partial invalidated by Trash erasure (410): must delete partial and never publish.
        do {
            let server = try LocalExportServer(payload: payload, etag: etag, mode: .goneErased)
            defer { server.stop() }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-fullpart-erased-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let dest = dir.appendingPathComponent("solstone-journal.zip")
            let fullPart = dir.appendingPathComponent(".solstone-export-exp_full_mac_2-1.part")
            try payload.write(to: fullPart)

            let manager = JournalExportTransferManager(
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 1 * 1024 * 1024 }
            )
            let host = JournalExportHost(
                contract: contract,
                manager: manager,
                liveBaseURL: { server.baseURL },
                transportKind: { "local" },
                presentSavePanel: { _, _ in dest }
            )
            _ = await host.handle([
                "id": "full-erased",
                "export_id": "exp_full_mac_2",
                "download_path": "/app/export/api/ready/exp_full_mac_2/download",
                "filename": "solstone-journal.zip",
                "size_bytes": size,
                "sha256": sha,
                "etag": etag,
            ], type: contract.start)

            let failed = await waitForPhase(manager, target: ["error", "saved"])
            #expect(failed.phase == "error")
            #expect(failed.errorCode == "export_invalidated_by_erasure")
            #expect(!FileManager.default.fileExists(atPath: dest.path))
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".part") } ?? []
            #expect(leftovers.isEmpty)
        }
    }

    @Test func adoptPartialPreservesSourceOnFailedRenameAndNeverDeletesNonRegularItems() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-exp-adopt-safe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exportID = "exp_adopt_1"
        let preferred = dir.appendingPathComponent(".solstone-export-\(exportID)-2.part")
        let staleRegular = dir.appendingPathComponent(".solstone-export-\(exportID)-1.part")
        let target = dir.appendingPathComponent(".solstone-export-\(exportID)-3.part")
        let matchingDir = dir.appendingPathComponent(".solstone-export-\(exportID)-10.part")
        let externalFile = dir.appendingPathComponent("keep-outside.txt")
        let matchingSymlink = dir.appendingPathComponent(".solstone-export-\(exportID)-9.part")

        let preferredBytes = Data("preferred-partial-bytes".utf8)
        try preferredBytes.write(to: preferred)
        try Data("stale-old".utf8).write(to: staleRegular)
        try FileManager.default.createDirectory(at: matchingDir, withIntermediateDirectories: true)
        try Data("outside-sentinel".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(at: matchingSymlink, withDestinationURL: externalFile)

        let adopted = JournalExportTransferManager.adoptOrCleanExistingPartials(
            in: dir,
            exportID: exportID,
            preferredSource: preferred,
            targetPartURL: target,
            renameFile: { _, _ in false }
        )

        #expect(adopted.lastPathComponent == preferred.lastPathComponent)
        #expect(try Data(contentsOf: preferred) == preferredBytes, "source partial must be preserved when rename fails")
        #expect(!FileManager.default.fileExists(atPath: staleRegular.path), "stale owned regular partial should be cleaned")
        var dirStat = stat()
        #expect(matchingDir.path.withCString { Darwin.lstat($0, &dirStat) } == 0 && (dirStat.st_mode & S_IFMT) == S_IFDIR)
        var linkStat = stat()
        #expect(matchingSymlink.path.withCString { Darwin.lstat($0, &linkStat) } == 0 && (linkStat.st_mode & S_IFMT) == S_IFLNK)
        #expect(try Data(contentsOf: externalFile) == Data("outside-sentinel".utf8))
    }
}
