// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum IngestDayKey {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    static func string(from date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return ""
        }
        return String(format: "%04d%02d%02d", year, month, day)
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func startOfDay(dayKey: String) -> Date? {
        guard dayKey.count == 8, dayKey.allSatisfy(\.isNumber) else { return nil }
        guard let year = Int(dayKey.prefix(4)),
              let month = Int(dayKey.dropFirst(4).prefix(2)),
              let day = Int(dayKey.suffix(2)) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.startOfDay(for: date)
    }
}

/// The linked-device journal ingest protocol. Keep shared wire vocabulary here so
/// every request and response uses the same contract.
public enum IngestProtocolV3 {
    static let headerName = "X-Solstone-Protocol-Version"
    static let headerValue = "3"
    static let maxPartBytes = 64 * 1024 * 1024
    static let maxConnectionBodyBytes = 128 * 1024 * 1024
    static let maxFiles = 8
    static let maxParts = 12
    static let maxFilenameBytes = 128
    static let maxHeaders = 16

    static let uploadPath = "/app/devices/ingest"

    static func segmentsDayPath(_ day: String) -> String {
        "\(uploadPath)/segments/\(day)"
    }

    enum Custody: Sendable, Equatable {
        case present
        case processed
        case missing
        case outOfContract(String)

        var provesHold: Bool {
            switch self {
            case .present, .processed:
                true
            case .missing, .outOfContract:
                false
            }
        }
    }

    enum UploadStatus: String, Codable, Sendable, Equatable {
        case ok
        case collision
        case duplicate
    }

    struct SegmentsDay: Decodable, Sendable, Equatable {
        let protocolVersion: Int
        let total: Int
        let items: [SegmentsItem]

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case total
            case items
        }

        init(protocolVersion: Int = 3, total: Int, items: [SegmentsItem]) {
            self.protocolVersion = protocolVersion
            self.total = total
            self.items = items
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
            let total = try values.decode(Int.self, forKey: .total)
            let items = try values.decode([SegmentsItem].self, forKey: .items)

            guard protocolVersion == 3, total >= 0, total == items.count else {
                throw UploadError.invalidResponse
            }
            var canonicalKeys: Set<String> = []
            for item in items {
                guard !item.key.isEmpty, canonicalKeys.insert(item.key).inserted else {
                    throw UploadError.invalidResponse
                }
            }

            var allKeys = canonicalKeys
            for item in items {
                if let originalKey = item.originalKey,
                   (originalKey.isEmpty || !allKeys.insert(originalKey).inserted) {
                    throw UploadError.invalidResponse
                }
            }

            self.protocolVersion = protocolVersion
            self.total = total
            self.items = items
        }
    }

    struct SegmentsItem: Decodable, Sendable, Equatable {
        let key: String
        let files: [ReadFile]
        let originalKey: String?

        enum CodingKeys: String, CodingKey {
            case key
            case files
            case originalKey = "original_key"
        }

        init(key: String, files: [ReadFile], originalKey: String? = nil) {
            self.key = key
            self.files = files
            self.originalKey = originalKey
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let key = try values.decode(String.self, forKey: .key)
            let files = try values.decode([ReadFile].self, forKey: .files)
            let originalKey = try values.decodeIfPresent(String.self, forKey: .originalKey)
            try validateFiles(files)

            self.key = key
            self.files = files
            self.originalKey = originalKey
        }
    }

    struct ReadFile: Decodable, Sendable, Equatable {
        let name: String
        let size: UInt64
        let sha256: String
        let status: Custody
        let submittedName: String?

        enum CodingKeys: String, CodingKey {
            case name
            case size
            case sha256
            case status
            case submittedName = "submitted_name"
        }

        init(name: String, size: UInt64, sha256: String, status: Custody, submittedName: String? = nil) {
            self.name = name
            self.size = size
            self.sha256 = sha256
            self.status = status
            self.submittedName = submittedName
        }

        var effectiveName: String {
            submittedName ?? name
        }
    }

    public enum UploadFileDisposition: Codable, Sendable, Equatable, Hashable {
        case written
        case alreadyHeld
        case receivedNotWritten
        case outOfContract(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "written": self = .written
            case "already_held": self = .alreadyHeld
            case "received_not_written": self = .receivedNotWritten
            default: self = .outOfContract(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .written: try container.encode("written")
            case .alreadyHeld: try container.encode("already_held")
            case .receivedNotWritten: try container.encode("received_not_written")
            case .outOfContract(let value): try container.encode(value)
            }
        }
    }

    struct UploadFileDescriptor: Codable, Sendable, Equatable {
        let submitted: String
        let written: String
        let size: UInt64
        let sha256: String
        let disposition: UploadFileDisposition

        enum CodingKeys: String, CodingKey {
            case submitted
            case written
            case size
            case sha256
            case disposition
        }

        init(submitted: String, written: String, size: UInt64, sha256: String, disposition: UploadFileDisposition) {
            self.submitted = submitted
            self.written = written
            self.size = size
            self.sha256 = sha256
            self.disposition = disposition
        }
    }

    struct UploadResponse: Decodable, Sendable, Equatable {
        let status: UploadStatus
        let storedSegmentKey: String
        let segmentOriginal: String?
        let fileDescriptors: [UploadFileDescriptor]
        let meta: [String: IngestJSONValue]

        private enum CodingKeys: String, CodingKey {
            case status
            case segment
            case existingSegment = "existing_segment"
            case segmentOriginal = "segment_original"
            case fileDescriptors = "file_descriptors"
            case meta
        }

        init(
            status: UploadStatus,
            storedSegmentKey: String,
            segmentOriginal: String? = nil,
            fileDescriptors: [UploadFileDescriptor] = [],
            meta: [String: IngestJSONValue] = [:]
        ) {
            self.status = status
            self.storedSegmentKey = storedSegmentKey
            self.segmentOriginal = segmentOriginal
            self.fileDescriptors = fileDescriptors
            self.meta = meta
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            status = try values.decode(UploadStatus.self, forKey: .status)
            let keyName: CodingKeys = status == .duplicate ? .existingSegment : .segment
            storedSegmentKey = try values.decode(String.self, forKey: keyName)
            guard !storedSegmentKey.isEmpty else { throw UploadError.invalidResponse }
            segmentOriginal = try values.decodeIfPresent(String.self, forKey: .segmentOriginal)
            if status == .collision {
                guard let segmentOriginal, !segmentOriginal.isEmpty else {
                    throw UploadError.invalidResponse
                }
            }
            fileDescriptors = try values.decode([UploadFileDescriptor].self, forKey: .fileDescriptors)
            meta = try values.decode([String: IngestJSONValue].self, forKey: .meta)
        }

        func validate(
            stagedFiles: [IngestAcknowledgedFileProof],
            stagedMeta: [String: IngestJSONValue]?,
            submittedSegment: String
        ) -> Bool {
            guard IngestProtocolV3.isSafePathComponent(storedSegmentKey),
                  IngestProtocolV3.isSafePathComponent(submittedSegment),
                  Set(stagedFiles.map(\.submitted)).count == stagedFiles.count else { return false }
            if status == .ok && storedSegmentKey != submittedSegment { return false }
            if status == .collision {
                guard segmentOriginal == submittedSegment else { return false }
            }
            guard !fileDescriptors.isEmpty, fileDescriptors.count == stagedFiles.count else {
                return false
            }

            var descriptorBySubmitted: [String: UploadFileDescriptor] = [:]
            for descriptor in fileDescriptors {
                guard IngestProtocolV3.isSafePathComponent(descriptor.submitted),
                      IngestProtocolV3.isSafePathComponent(descriptor.written),
                      descriptorBySubmitted[descriptor.submitted] == nil else {
                    return false
                }
                descriptorBySubmitted[descriptor.submitted] = descriptor
            }

            for staged in stagedFiles {
                guard let descriptor = descriptorBySubmitted[staged.submitted] else {
                    return false
                }
                guard descriptor.sha256 == staged.sha256,
                      descriptor.size == staged.size else {
                    return false
                }
                guard descriptor.disposition == .written || descriptor.disposition == .alreadyHeld else {
                    return false
                }
            }

            let expectedMeta = stagedMeta ?? [:]
            guard meta == expectedMeta else {
                return false
            }

            return true
        }
    }

    static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/")
            && value.utf8.allSatisfy { $0 >= 32 && $0 != 127 }
            && (value as NSString).lastPathComponent == value
    }

    private static func validateFiles(_ files: [ReadFile]) throws {
        var names: Set<String> = []
        for file in files {
            guard !file.name.isEmpty,
                  !file.effectiveName.isEmpty,
                  !file.sha256.isEmpty,
                  names.insert(file.effectiveName).inserted else {
                throw UploadError.invalidResponse
            }
        }
    }
}

extension IngestProtocolV3.Custody: Codable {
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case "present": self = .present
        case "processed": self = .processed
        case "missing": self = .missing
        default: self = .outOfContract(rawValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let rawValue: String
        switch self {
        case .present: rawValue = "present"
        case .processed: rawValue = "processed"
        case .missing: rawValue = "missing"
        case .outOfContract(let value): rawValue = value
        }
        try container.encode(rawValue)
    }
}

enum IngestJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case object([String: IngestJSONValue])
    case array([IngestJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: IngestJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([IngestJSONValue].self) {
            self = .array(value)
        } else {
            throw UploadError.invalidResponse
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
