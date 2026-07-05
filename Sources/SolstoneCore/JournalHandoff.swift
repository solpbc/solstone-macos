// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum JournalHandoffFile {
    public static func url(
        applicationSupportBaseURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        applicationSupportBaseURL
            .appendingPathComponent("sol", isDirectory: true)
            .appendingPathComponent("journal-handoff.json")
    }
}

public struct JournalHandoff: Codable, Sendable, Equatable {
    public let journalRootPath: String
    public let observerName: String
    public let provenance: String
    public let timestamp: Date

    public init(journalRootPath: String, observerName: String, provenance: String, timestamp: Date) {
        self.journalRootPath = journalRootPath
        self.observerName = observerName
        self.provenance = provenance
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case journalRootPath
        case observerName
        case provenance
        case timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        journalRootPath = try container.decode(String.self, forKey: .journalRootPath)
        observerName = try container.decode(String.self, forKey: .observerName)
        provenance = try container.decode(String.self, forKey: .provenance)
        let timestampString = try container.decode(String.self, forKey: .timestamp)
        guard let timestamp = Self.decodeTimestamp(timestampString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "timestamp must be an ISO-8601 string"
            )
        }
        self.timestamp = timestamp
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(journalRootPath, forKey: .journalRootPath)
        try container.encode(observerName, forKey: .observerName)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(Self.encodeTimestamp(timestamp), forKey: .timestamp)
    }

    private static func encodeTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func decodeTimestamp(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
