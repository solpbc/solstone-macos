// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// A cheap change detector for upload reconciliation, never a deletion proof.
struct IngestLocalFileVersion: Codable, Equatable, Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    private init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }

    static func read(_ url: URL) -> Self? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return Self(info)
    }

    static func read(fileDescriptor: Int32) -> Self? {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return Self(info)
    }

    var hasSubsecondTimes: Bool {
        modifiedNanoseconds != 0 && changedNanoseconds != 0
    }
}

struct IngestAcknowledgedFileProof: Sendable, Equatable, Hashable {
    let submitted: String
    let written: String
    let sha256: String
    let size: UInt64
    let localVersion: IngestLocalFileVersion?
    let disposition: IngestProtocolV3.UploadFileDisposition?

    init(
        submitted: String,
        sha256: String,
        size: UInt64,
        written: String? = nil,
        localVersion: IngestLocalFileVersion? = nil,
        disposition: IngestProtocolV3.UploadFileDisposition? = nil
    ) {
        self.submitted = submitted
        self.written = written ?? submitted
        self.sha256 = sha256
        self.size = size
        self.localVersion = localVersion
        self.disposition = disposition
    }

    enum CodingKeys: String, CodingKey {
        case submitted
        case written
        case sha256
        case size
        case localVersion
        case disposition
    }

    func matchesLocalFileForUpload(_ url: URL, sha256Calculator: (URL) -> String?) -> Bool {
        guard let current = IngestLocalFileVersion.read(url), current.size >= 0,
              UInt64(current.size) == size else { return false }
        if let localVersion, localVersion.hasSubsecondTimes, localVersion == current {
            return true
        }
        return sha256Calculator(url) == sha256
    }
}

extension IngestAcknowledgedFileProof: Codable {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let submitted = try values.decode(String.self, forKey: .submitted)
        self.submitted = submitted
        self.written = try values.decodeIfPresent(String.self, forKey: .written) ?? submitted
        self.sha256 = try values.decode(String.self, forKey: .sha256)
        self.size = try values.decode(UInt64.self, forKey: .size)
        self.localVersion = try values.decodeIfPresent(IngestLocalFileVersion.self, forKey: .localVersion)
        self.disposition = try values.decodeIfPresent(IngestProtocolV3.UploadFileDisposition.self, forKey: .disposition)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(submitted, forKey: .submitted)
        try container.encode(written, forKey: .written)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(localVersion, forKey: .localVersion)
        try container.encodeIfPresent(disposition, forKey: .disposition)
    }
}

struct IngestAcknowledgmentPayload: Sendable, Equatable, Codable {
    let files: [IngestAcknowledgedFileProof]
    let meta: [String: IngestJSONValue]

    init(files: [IngestAcknowledgedFileProof], meta: [String: IngestJSONValue]) {
        self.files = files
        self.meta = meta
    }
}

struct IngestAcknowledgment: Sendable, Equatable, Codable {
    let journalFingerprint: String
    let day: String
    let submittedSegment: String
    let storedSegmentKey: String
    let status: IngestProtocolV3.UploadStatus
    let payload: IngestAcknowledgmentPayload
    let removedMedia: [IngestAcknowledgedFileProof]

    static func isUploadMediaName(_ name: String, segment: String) -> Bool {
        IngestProtocolV3.isSafePathComponent(name)
            && (name.hasSuffix("_screen.mp4") || name == "\(segment)_audio.m4a")
    }

    var isValid: Bool {
        guard !journalFingerprint.isEmpty,
              IngestProtocolV3.isSafePathComponent(day),
              IngestProtocolV3.isSafePathComponent(submittedSegment),
              IngestProtocolV3.isSafePathComponent(storedSegmentKey),
              !payload.files.isEmpty else { return false }
        var names: Set<String> = []
        for file in payload.files + removedMedia {
            guard Self.isUploadMediaName(file.submitted, segment: submittedSegment),
                  IngestProtocolV3.isSafePathComponent(file.written),
                  file.sha256.count == 64,
                  file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  names.insert(file.submitted).inserted else { return false }
        }
        return true
    }

    init(
        journalFingerprint: String,
        day: String,
        submittedSegment: String,
        storedSegmentKey: String,
        status: IngestProtocolV3.UploadStatus,
        payload: IngestAcknowledgmentPayload,
        removedMedia: [IngestAcknowledgedFileProof] = []
    ) {
        self.journalFingerprint = journalFingerprint
        self.day = day
        self.submittedSegment = submittedSegment
        self.storedSegmentKey = storedSegmentKey
        self.status = status
        self.payload = payload
        self.removedMedia = removedMedia
    }

    static func successor(
        previous: IngestAcknowledgment?,
        journalFingerprint: String,
        day: String,
        submittedSegment: String,
        storedSegmentKey: String,
        status: IngestProtocolV3.UploadStatus,
        newPayload: IngestAcknowledgmentPayload,
        segmentDirectory: URL,
        sha256Calculator: @Sendable (URL) -> String?
    ) -> IngestAcknowledgment {
        var removed: [String: IngestAcknowledgedFileProof] = [:]
        if let previous,
           previous.journalFingerprint == journalFingerprint,
           previous.day == day,
           previous.submittedSegment == submittedSegment {
            for file in previous.removedMedia {
                removed[file.submitted] = file
            }
            for file in previous.payload.files {
                let localURL = segmentDirectory.appendingPathComponent(file.submitted)
                var stillMatches = false
                if let values = try? localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                   values.isSymbolicLink != true,
                   values.isRegularFile == true,
                   let fileSize = values.fileSize,
                   UInt64(fileSize) == file.size,
                   let localSHA = sha256Calculator(localURL),
                   localSHA == file.sha256 {
                    stillMatches = true
                }
                if !stillMatches {
                    removed[file.submitted] = file
                }
            }
        }
        for file in newPayload.files {
            removed.removeValue(forKey: file.submitted)
        }
        let sortedRemoved = removed.values.sorted { $0.submitted < $1.submitted }
        return IngestAcknowledgment(
            journalFingerprint: journalFingerprint,
            day: day,
            submittedSegment: submittedSegment,
            storedSegmentKey: storedSegmentKey,
            status: status,
            payload: newPayload,
            removedMedia: sortedRemoved
        )
    }
}

enum IngestAcknowledgmentStore {
    static func acknowledgmentURL(segmentDirectory: URL, segment: String) -> URL {
        segmentDirectory.appendingPathComponent("\(segment)_ingest_ack.json")
    }

    static func read(from fileURL: URL) -> IngestAcknowledgment? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        guard let acknowledgment = try? decoder.decode(IngestAcknowledgment.self, from: data),
              acknowledgment.isValid else { return nil }
        return acknowledgment
    }

    static func write(_ acknowledgment: IngestAcknowledgment, to fileURL: URL) throws {
        guard acknowledgment.isValid else { throw IngestAcknowledgmentStoreError.invalidAcknowledgment }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(acknowledgment)

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
              let decoded = try? JSONDecoder().decode(IngestAcknowledgment.self, from: stagedData),
              decoded == acknowledgment else {
            throw IngestAcknowledgmentStoreError.stagedValidationFailed
        }

        guard Darwin.rename(stagingURL.path, fileURL.path) == 0 else {
            throw IngestAcknowledgmentStoreError.renameFailed(errno: errno)
        }
        committed = true
    }
}

enum IngestAcknowledgmentStoreError: Error, Equatable {
    case invalidAcknowledgment
    case stagedValidationFailed
    case renameFailed(errno: Int32)
}
