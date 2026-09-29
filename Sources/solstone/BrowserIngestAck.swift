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

enum BrowserIngestAckError: Error {
    case parentSyncFailed
}

enum BrowserIngestAckStore {
    static func ackURL(periodDirectory: URL) -> URL {
        periodDirectory.appendingPathComponent("browser_ingest_ack.json")
    }

    static func read(from fileURL: URL) -> BrowserIngestAck? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BrowserIngestAck.self, from: data)
    }

    static func write(_ ack: BrowserIngestAck, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ack)

        let directory = fileURL.deletingLastPathComponent()
        let stagingURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        try data.write(to: stagingURL)
        let handle = try FileHandle(forWritingTo: stagingURL)
        defer { try? handle.close() }
        try handle.synchronize()

        guard let stagedData = try? Data(contentsOf: stagingURL),
              stagedData == data,
              let decoded = try? JSONDecoder().decode(BrowserIngestAck.self, from: stagedData),
              decoded == ack else {
            throw IngestAcknowledgmentStoreError.stagedValidationFailed
        }

        guard Darwin.rename(stagingURL.path, fileURL.path) == 0 else {
            throw IngestAcknowledgmentStoreError.renameFailed(errno: errno)
        }
        committed = true

        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw BrowserIngestAckError.parentSyncFailed }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw BrowserIngestAckError.parentSyncFailed }
    }
}

#endif
