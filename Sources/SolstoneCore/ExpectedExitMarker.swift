// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// L1 ships the marker FORMAT + READER + VALIDATOR only. Writing the marker on the observer's deliberate-quit path is L2 (out of scope here).
public struct ExpectedExitMarker: Codable, Sendable, Equatable {
    public let pid: Int32
    public let timestamp: Date
    public let reason: String

    public init(pid: Int32, timestamp: Date, reason: String) {
        self.pid = pid
        self.timestamp = timestamp
        self.reason = reason
    }

    public static var markerURL: URL {
        SolMacIPCConstants.solstoneApplicationSupportURL.appendingPathComponent("expected-exit.json")
    }

    public static let defaultFreshnessWindow: TimeInterval = 120
    public static let defaultThrottleLimit = 3
    public static let defaultThrottleWindow: TimeInterval = 60

    /// Uses JSONEncoder's default reference-date numeric Date strategy; round-trip safe with `decode(_:)`.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> ExpectedExitMarker {
        try JSONDecoder().decode(ExpectedExitMarker.self, from: data)
    }

    public static func isExpectedExit(
        marker: ExpectedExitMarker?,
        terminatedPID: Int32,
        now: Date,
        freshnessWindow: TimeInterval = defaultFreshnessWindow
    ) -> Bool {
        guard let marker else { return false }
        return now.timeIntervalSince(marker.timestamp) <= freshnessWindow && marker.pid == terminatedPID
    }

    public static func readAndConsume(
        at url: URL = markerURL,
        fileManager: FileManager = .default
    ) -> ExpectedExitMarker? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        defer {
            try? fileManager.removeItem(at: url)
        }

        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? decode(data)
    }
}
