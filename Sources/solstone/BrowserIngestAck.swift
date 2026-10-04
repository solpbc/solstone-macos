// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Darwin
import Foundation

struct BrowserIngestAck: Codable, Sendable, Equatable {
    let generation: String
    let source: String
    let periodId: String
    let filename: String
    let sha256: String
    let size: UInt64
    let metadata: [String: IngestJSONValue]?
    let requestedDay: String
    let requestedSegment: String
    let canonicalKey: String?
    let status: IngestProtocolV3.UploadStatus

    static func == (lhs: BrowserIngestAck, rhs: BrowserIngestAck) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let lhsData = try? encoder.encode(lhs), let rhsData = try? encoder.encode(rhs) else { return false }
        return lhsData == rhsData
    }

    init(
        generation: String,
        source: String = "browser",
        periodId: String,
        filename: String = "browser_pages.jsonl",
        sha256: String,
        size: UInt64,
        metadata: [String: IngestJSONValue]?,
        requestedDay: String,
        requestedSegment: String,
        canonicalKey: String?,
        status: IngestProtocolV3.UploadStatus
    ) {
        self.generation = generation
        self.source = source
        self.periodId = periodId
        self.filename = filename
        self.sha256 = sha256
        self.size = size
        self.metadata = metadata
        self.requestedDay = requestedDay
        self.requestedSegment = requestedSegment
        self.canonicalKey = canonicalKey
        self.status = status
    }
}

struct BrowserDeliveryBinding: Codable, Sendable, Equatable {
    let ack: BrowserIngestAck
    let serverURL: String
    let identityDigest: String
    let pairingGeneration: UInt64
    let transportIncarnation: UInt64

    init(ack: BrowserIngestAck, route: BrowserIntakeRouteCapability) {
        self.ack = ack
        serverURL = route.serverURL
        identityDigest = route.identityDigest
        pairingGeneration = route.pairingGeneration
        transportIncarnation = route.transportIncarnation
    }

    func namesSameConnection(as route: BrowserIntakeRouteCapability) -> Bool {
        route.namesSameConnection(
            serverURL: serverURL,
            identityDigest: identityDigest,
            pairingGeneration: pairingGeneration,
            transportIncarnation: transportIncarnation
        )
    }
}

enum BrowserIngestAckError: Error {
    case parentSyncFailed
}

enum BrowserIngestAckStore {
    static let maximumBytes = 4096
    static func ackURL(periodDirectory: URL) -> URL {
        periodDirectory.appendingPathComponent("browser_ingest_ack.json")
    }

    static func read(from fileURL: URL, ioInjector: BrowserIntakeIOInjector? = nil) throws -> BrowserIngestAck? {
        try assertNoSymlinkAncestors(fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        var info = stat()
        guard lstat(fileURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maximumBytes else {
            throw BrowserIntakeStoreError.localIO
        }
        try ioInjector?.check(.read)
        let data = try Data(contentsOf: fileURL)
        guard let ack = try? JSONDecoder().decode(BrowserIngestAck.self, from: data) else {
            throw BrowserIntakeStoreError.localIO
        }
        return ack
    }

    static func write(_ ack: BrowserIngestAck, to fileURL: URL, ioInjector: BrowserIntakeIOInjector? = nil) throws {
        try assertNoSymlinkAncestors(fileURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ack)
        guard data.count <= maximumBytes else { throw BrowserIntakeStoreError.localIO }

        let directory = fileURL.deletingLastPathComponent()
        let stagingURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

        var committed = false
        defer {
            if !committed {
                try? ioInjector?.check(.write)
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        try assertNoSymlinkAncestors(stagingURL)
        try ioInjector?.check(.write)
        try data.write(to: stagingURL)
        let handle = try FileHandle(forWritingTo: stagingURL)
        defer { try? handle.close() }
        try ioInjector?.check(.sync)
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else { throw BrowserIngestAckError.parentSyncFailed }

        try ioInjector?.check(.read)
        guard let stagedData = try? Data(contentsOf: stagingURL),
              stagedData == data,
              let decoded = try? JSONDecoder().decode(BrowserIngestAck.self, from: stagedData),
              decoded == ack else {
            throw IngestAcknowledgmentStoreError.stagedValidationFailed
        }

        try ioInjector?.check(.write)
        guard Darwin.rename(stagingURL.path, fileURL.path) == 0 else {
            throw IngestAcknowledgmentStoreError.renameFailed(errno: errno)
        }
        committed = true

        try syncParent(of: fileURL, ioInjector: ioInjector)
    }

    static func syncParent(of fileURL: URL, ioInjector: BrowserIntakeIOInjector? = nil) throws {
        try assertNoSymlinkAncestors(fileURL)
        try ioInjector?.check(.sync)
        let fd = open(fileURL.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw BrowserIngestAckError.parentSyncFailed }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw BrowserIngestAckError.parentSyncFailed }
    }

    private static func assertNoSymlinkAncestors(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/")
        for component in url.path.split(separator: "/") {
            current.appendPathComponent(String(component))
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw BrowserIngestAckError.parentSyncFailed }
            } else if errno != ENOENT {
                throw BrowserIngestAckError.parentSyncFailed
            }
        }
    }
}

#endif
