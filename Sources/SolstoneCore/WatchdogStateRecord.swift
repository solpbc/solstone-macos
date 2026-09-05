// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation

public struct WatchdogStateRecord: Codable, Equatable, Sendable {
    public let cause: WatchdogStateCause
    public let enclosingBundleURL: URL?
    public let enclosingBundleIdentifier: String?
    public let writerExecutableURL: URL
    public let timestamp: Date
    public let conflictingBundleURL: URL?
    public let conflictingBundleShortVersion: String?
    public let conflictingBundleBuild: String?

    public init(
        cause: WatchdogStateCause,
        enclosingBundleURL: URL?,
        enclosingBundleIdentifier: String?,
        writerExecutableURL: URL,
        timestamp: Date = Date(),
        conflictingBundleURL: URL? = nil,
        conflictingBundleShortVersion: String? = nil,
        conflictingBundleBuild: String? = nil
    ) {
        self.cause = cause
        self.enclosingBundleURL = enclosingBundleURL
        self.enclosingBundleIdentifier = enclosingBundleIdentifier
        self.writerExecutableURL = writerExecutableURL
        self.timestamp = timestamp
        self.conflictingBundleURL = conflictingBundleURL
        self.conflictingBundleShortVersion = conflictingBundleShortVersion
        self.conflictingBundleBuild = conflictingBundleBuild
    }

    public init(refusal: WatchdogRefusal, timestamp: Date = Date()) {
        self.init(
            cause: refusal.cause,
            enclosingBundleURL: refusal.enclosingBundleURL,
            enclosingBundleIdentifier: refusal.enclosingBundleIdentifier,
            writerExecutableURL: refusal.writerExecutableURL,
            timestamp: timestamp
        )
    }
}

public enum WatchdogStateRecordStore {
    public static func directoryURL(
        applicationSupportBaseURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        applicationSupportBaseURL
            .appendingPathComponent("Solstone", isDirectory: true)
            .appendingPathComponent("watchdog-state", isDirectory: true)
    }

    public static func fileURL(
        for record: WatchdogStateRecord,
        applicationSupportBaseURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        let keyURL = record.enclosingBundleURL ?? record.writerExecutableURL
        let normalizedURL = WatchdogAppLocationEligibility.normalized(keyURL)
        let digest = SHA256.hash(data: Data(normalizedURL.absoluteString.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let name = sanitizedName(from: keyURL)
        return directoryURL(applicationSupportBaseURL: applicationSupportBaseURL)
            .appendingPathComponent("\(name)-\(digest).json")
    }

    public static func write(
        _ record: WatchdogStateRecord,
        applicationSupportBaseURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        fileManager: FileManager = .default
    ) throws {
        let directory = directoryURL(applicationSupportBaseURL: applicationSupportBaseURL)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL(for: record, applicationSupportBaseURL: applicationSupportBaseURL), options: .atomic)
    }

    private static func sanitizedName(from url: URL) -> String {
        let source = url.lastPathComponent.isEmpty ? "watchdog" : url.lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let sanitized = String(source.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
        // This is a diagnostic-record filename, not a security boundary. The digest keeps distinct bundle URLs apart; the readable prefix helps human debugging.
        return String(sanitized.prefix(80))
    }
}
