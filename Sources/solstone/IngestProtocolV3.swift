// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The linked-device journal ingest protocol. Keep shared wire vocabulary here so
/// every request and response uses the same contract.
enum IngestProtocolV3 {
    static let headerName = "X-Solstone-Protocol-Version"
    static let headerValue = "3"
    static let maxPartBytes = 64 * 1024 * 1024
    static let maxConnectionBodyBytes = 128 * 1024 * 1024
    static let maxFiles = 8
    static let maxParts = 12
    static let maxFilenameBytes = 128
    static let maxHeaders = 16

    static let uploadPath = "/app/devices/ingest"
    static let manifestPath = "/app/devices/ingest/manifest"

    static func manifestDayPath(_ day: String) -> String {
        "\(manifestPath)/\(day)"
    }

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

    struct Manifest: Decodable, Sendable, Equatable {
        let days: [String: Day]

        enum Day: Decodable, Sendable, Equatable {
            case segments(Int)
            case error(String)

            private enum CodingKeys: String, CodingKey {
                case segments
                case error
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                let hasSegments = values.contains(.segments)
                let hasError = values.contains(.error)
                guard hasSegments != hasError else {
                    throw UploadError.invalidResponse
                }
                if hasSegments {
                    let count = try values.decode(Int.self, forKey: .segments)
                    guard count >= 0 else { throw UploadError.invalidResponse }
                    self = .segments(count)
                } else {
                    let error = try values.decode(String.self, forKey: .error)
                    guard !error.isEmpty else { throw UploadError.invalidResponse }
                    self = .error(error)
                }
            }
        }
    }

    struct ManifestDay: Decodable, Sendable, Equatable {
        let version: Int
        let day: String
        let segments: [String: ManifestSegment]

        enum CodingKeys: String, CodingKey {
            case version
            case day
            case segments
        }

        func validate(expectedDay: String) throws {
            guard version == 1, day == expectedDay else {
                throw UploadError.invalidResponse
            }
            for key in segments.keys {
                guard !key.isEmpty else { throw UploadError.invalidResponse }
            }
        }
    }

    struct ManifestSegment: Decodable, Sendable, Equatable {
        let files: [ReadFile]

        private enum CodingKeys: String, CodingKey {
            case files
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let files = try values.decode([ReadFile].self, forKey: .files)
            try validateFiles(files)
            self.files = files
        }
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
        let observed: Bool
        let files: [ReadFile]
        let originalKey: String?

        enum CodingKeys: String, CodingKey {
            case key
            case observed
            case files
            case originalKey = "original_key"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let key = try values.decode(String.self, forKey: .key)
            let observed = try values.decode(Bool.self, forKey: .observed)
            let files = try values.decode([ReadFile].self, forKey: .files)
            let originalKey = try values.decodeIfPresent(String.self, forKey: .originalKey)
            try validateFiles(files)

            self.key = key
            self.observed = observed
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

        var effectiveName: String {
            submittedName ?? name
        }
    }

    struct UploadResponse: Decodable, Sendable, Equatable {
        let status: UploadStatus
        let storedSegmentKey: String

        private enum CodingKeys: String, CodingKey {
            case status
            case segment
            case existingSegment = "existing_segment"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            status = try values.decode(UploadStatus.self, forKey: .status)
            let keyName: CodingKeys = status == .duplicate ? .existingSegment : .segment
            storedSegmentKey = try values.decode(String.self, forKey: keyName)
            guard !storedSegmentKey.isEmpty else { throw UploadError.invalidResponse }
        }
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
