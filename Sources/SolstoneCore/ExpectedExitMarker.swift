// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

/// Expected-exit marker format, reader, validator, and best-effort writer.
public struct ExpectedExitMarker: Codable, Sendable, Equatable {
    public let pid: Int32
    public let timestamp: Date
    public let reason: String

    public init(pid: Int32, timestamp: Date, reason: String) {
        self.pid = pid
        self.timestamp = timestamp
        self.reason = reason
    }

    public static let solMarkerDiscriminator = "Solstone"
    public static let journalMarkerDiscriminator = "SolstoneJournal"

    public static var markerURL: URL {
        markerURL(for: solMarkerDiscriminator)
    }

    public static func markerURL(
        for discriminator: String,
        applicationSupportBaseURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        applicationSupportBaseURL
            .appendingPathComponent(discriminator, isDirectory: true)
            .appendingPathComponent("expected-exit.json")
    }

    public static let defaultFreshnessWindow: TimeInterval = 120
    public static let defaultThrottleLimit = 3
    public static let defaultThrottleWindow: TimeInterval = 60

    /// Uses JSONEncoder's default reference-date numeric Date strategy; round-trip safe with `decode(_:)`.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Writes a fresh expected-exit marker for the current process before an intentional
    /// teardown. Best-effort: never throws into the caller, so a failed write can never
    /// block termination. The marker is consumed by the watchdog (L3); until then it is
    /// simply overwritten by the next quit.
    public static func markExpectedExit(
        reason: String,
        now: Date = Date(),
        pid: Int32 = getpid(),
        at url: URL = markerURL,
        fileManager: FileManager = .default
    ) {
        let marker = ExpectedExitMarker(pid: pid, timestamp: now, reason: reason)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try marker.encoded().write(to: url, options: .atomic)
        } catch {
            Logger.general.warning("expected-exit marker write failed (reason=\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
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

    public static func invalidate(
        at url: URL = markerURL,
        fileManager: FileManager = .default
    ) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            Logger.general.warning("expected-exit marker invalidate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
