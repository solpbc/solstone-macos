// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

internal enum DiagnosticEvidenceCode: String, Codable, Equatable, Sendable, CaseIterable {
    case appLaunch = "app.launch"
    case screenRecordingGranted = "screen_recording.granted"
    case screenRecordingNotGranted = "screen_recording.not_granted"
    case screenRecordingUnavailable = "screen_recording.unavailable"
    case screenRecordingCDHashMismatch = "screen_recording.cdhash_mismatch"
    case microphoneGranted = "microphone.granted"
    case microphoneNotGranted = "microphone.not_granted"
    case microphoneUnavailable = "microphone.unavailable"
    case captureOn = "capture.on"
    case capturePaused = "capture.paused"
    case captureOff = "capture.off"
    case captureError = "capture.error"
    case terminationCommitted = "termination.committed"
    case terminationAppKitBegan = "termination.appkit_began"
    case permissionAutoStartSkipped = "permission.auto_start_skipped"
    case terminationDrainTimeout = "termination.drain_timeout"
    case deliveryWriteFailed = "delivery.write_failed"
    case syncSegmentUnprovable = "sync.segment_unprovable"
}

internal struct DiagnosticEvidenceEntry: Equatable, Sendable {
    var code: DiagnosticEvidenceCode
    var firstAt: Date
    var lastAt: Date
    var repeatCount: Int

    static let maxRepeatCount = 999

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case firstAt
        case lastAt
        case repeatCount
    }

    static let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

extension DiagnosticEvidenceEntry: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiagnosticEvidenceAnyKey.self)
        let names = Set(container.allKeys.map(\.stringValue))
        guard names == Self.allowedKeys else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "rejected")
            )
        }

        code = try container.decode(DiagnosticEvidenceCode.self, forKey: DiagnosticEvidenceAnyKey("code"))

        // Timestamps are validated as raw Unix seconds so out-of-range values are rejected rather than silently accepted.
        let firstAtRaw = try container.decode(Double.self, forKey: DiagnosticEvidenceAnyKey("firstAt"))
        let lastAtRaw = try container.decode(Double.self, forKey: DiagnosticEvidenceAnyKey("lastAt"))
        guard firstAtRaw.isFinite, lastAtRaw.isFinite, firstAtRaw >= 0, lastAtRaw >= 0 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "rejected")
            )
        }
        firstAt = Date(timeIntervalSince1970: firstAtRaw)
        lastAt = Date(timeIntervalSince1970: lastAtRaw)
        guard firstAt <= lastAt else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "rejected")
            )
        }

        let repeatRaw = try container.decode(Double.self, forKey: DiagnosticEvidenceAnyKey("repeatCount"))
        guard repeatRaw.isFinite,
              repeatRaw == repeatRaw.rounded(.towardZero),
              let parsedRepeat = Int(exactly: repeatRaw.rounded(.towardZero)),
              (1...Self.maxRepeatCount).contains(parsedRepeat) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "rejected")
            )
        }
        repeatCount = parsedRepeat
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(firstAt, forKey: .firstAt)
        try container.encode(lastAt, forKey: .lastAt)
        try container.encode(repeatCount, forKey: .repeatCount)
    }
}

internal struct DiagnosticEvidenceEnvelope: Equatable, Sendable {
    var schemaVersion: Int
    var entries: [DiagnosticEvidenceEntry]

    static let currentSchemaVersion = 1
    static let maxEntries = 128
    static let retentionInterval: TimeInterval = 7 * 86_400

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case entries
    }

    static let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    static func decoded(from data: Data, now: Date) throws -> DiagnosticEvidenceEnvelope {
        let envelope = try JSONDecoder().decode(DiagnosticEvidenceEnvelope.self, from: data)
        try envelope.validate(now: now)
        return envelope
    }

    func validate(now: Date) throws {
        // The future-time boundary is exact: no tolerance, rounding, or substitution. A producer time within one ULP of `now` can be rejected as future-dated; this is bounded and deliberate.
        for entry in entries {
            guard entry.firstAt <= now, entry.lastAt <= now else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "rejected")
                )
            }
        }
    }

    func pruned(now: Date) -> DiagnosticEvidenceEnvelope {
        let kept = entries.filter { now.timeIntervalSince($0.lastAt) <= Self.retentionInterval }
        return DiagnosticEvidenceEnvelope(schemaVersion: Self.currentSchemaVersion, entries: kept)
    }

    mutating func incorporating(code: DiagnosticEvidenceCode, at time: Date) {
        if entries.last?.code == code {
            let index = entries.count - 1
            entries[index].lastAt = max(entries[index].lastAt, time)
            entries[index].repeatCount = min(entries[index].repeatCount + 1, DiagnosticEvidenceEntry.maxRepeatCount)
        } else {
            entries.append(
                DiagnosticEvidenceEntry(code: code, firstAt: time, lastAt: time, repeatCount: 1)
            )
        }
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}

extension DiagnosticEvidenceEnvelope: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiagnosticEvidenceAnyKey.self)
        let names = Set(container.allKeys.map(\.stringValue))
        guard names == Self.allowedKeys else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "rejected")
            )
        }

        let versionRaw = try container.decode(Double.self, forKey: DiagnosticEvidenceAnyKey("schemaVersion"))
        guard versionRaw.isFinite,
              versionRaw == versionRaw.rounded(.towardZero),
              versionRaw == Double(Self.currentSchemaVersion) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "rejected")
            )
        }
        schemaVersion = Self.currentSchemaVersion

        entries = try container.decode([DiagnosticEvidenceEntry].self, forKey: DiagnosticEvidenceAnyKey("entries"))
        guard entries.count <= Self.maxEntries else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "rejected")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(entries, forKey: .entries)
    }
}

internal enum DiagnosticEvidenceRead: Equatable, Sendable {
    case available(DiagnosticEvidenceEnvelope)
    case unavailable
}

internal enum DiagnosticEvidenceRecordResult: Equatable, Sendable {
    case recorded
    case unavailable
}

internal enum DiagnosticEvidenceBytesRead: Equatable, Sendable {
    case absent
    case bytes(Data)
    case failed
}

internal struct DiagnosticEvidenceStagingHandle: Equatable, Sendable {
    let token: String
}

internal enum DiagnosticEvidenceEncodingResult: Equatable, Sendable {
    case encoded(Data)
    case failed
}

internal enum DiagnosticEvidenceStagingResult: Equatable, Sendable {
    case staged(DiagnosticEvidenceStagingHandle)
    case failed
}

internal enum DiagnosticEvidenceCommitResult: Equatable, Sendable {
    case committed
    case failed
}

internal protocol DiagnosticEvidenceBytesStoring: Sendable {
    func readCanonical() -> DiagnosticEvidenceBytesRead
    func encode(_ envelope: DiagnosticEvidenceEnvelope) -> DiagnosticEvidenceEncodingResult
    func stage(_ data: Data) -> DiagnosticEvidenceStagingResult
    func readStaged(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceBytesRead
    func commit(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceCommitResult
    func removeStaging(_ staging: DiagnosticEvidenceStagingHandle)
}

/// UserDefaults cannot host this seam: `data(forKey:)` maps both never-written and non-Data values to nil, so it cannot implement `DiagnosticEvidenceBytesRead`.
internal final class FileDiagnosticEvidenceBytesStore: DiagnosticEvidenceBytesStoring, @unchecked Sendable {
    let fileURL: URL

    init(
        applicationSupportBaseURL: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    ) {
        self.fileURL = Self.fileURL(applicationSupportBaseURL: applicationSupportBaseURL)
    }

    static func fileURL(applicationSupportBaseURL: URL) -> URL {
        applicationSupportBaseURL
            .appendingPathComponent("Solstone", isDirectory: true)
            .appendingPathComponent("diagnostic-evidence.json")
    }

    func readCanonical() -> DiagnosticEvidenceBytesRead {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .absent
        }
        do {
            return .bytes(try Data(contentsOf: fileURL))
        } catch {
            return .failed
        }
    }

    func encode(_ envelope: DiagnosticEvidenceEnvelope) -> DiagnosticEvidenceEncodingResult {
        do {
            return .encoded(try envelope.encoded())
        } catch {
            return .failed
        }
    }

    func stage(_ data: Data) -> DiagnosticEvidenceStagingResult {
        let stagingURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stagingURL)
            return .staged(DiagnosticEvidenceStagingHandle(token: stagingURL.path))
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            return .failed
        }
    }

    func readStaged(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceBytesRead {
        let stagingURL = URL(fileURLWithPath: staging.token)
        guard FileManager.default.fileExists(atPath: stagingURL.path) else {
            return .absent
        }
        do {
            return .bytes(try Data(contentsOf: stagingURL))
        } catch {
            return .failed
        }
    }

    // Same-directory POSIX rename is the sole commit point. Foundation's atomic-write and replacement APIs
    // are rejected here because they could replace canonical bytes before the actor validates staged bytes.
    func commit(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceCommitResult {
        if Darwin.rename(staging.token, fileURL.path) != 0 {
            return .failed
        }
        return .committed
    }

    func removeStaging(_ staging: DiagnosticEvidenceStagingHandle) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: staging.token))
    }
}

internal final class InMemoryDiagnosticEvidenceBytesStore: DiagnosticEvidenceBytesStoring, @unchecked Sendable {
    var stored: Data?
    var readOverride: DiagnosticEvidenceBytesRead?
    private var staged: [String: Data] = [:]

    func readCanonical() -> DiagnosticEvidenceBytesRead {
        if let readOverride {
            return readOverride
        }
        guard let stored else {
            return .absent
        }
        return .bytes(stored)
    }

    func encode(_ envelope: DiagnosticEvidenceEnvelope) -> DiagnosticEvidenceEncodingResult {
        do {
            return .encoded(try envelope.encoded())
        } catch {
            return .failed
        }
    }

    func stage(_ data: Data) -> DiagnosticEvidenceStagingResult {
        let token = UUID().uuidString
        staged[token] = data
        return .staged(DiagnosticEvidenceStagingHandle(token: token))
    }

    func readStaged(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceBytesRead {
        guard let data = staged[staging.token] else {
            return .absent
        }
        return .bytes(data)
    }

    func commit(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceCommitResult {
        guard let data = staged.removeValue(forKey: staging.token) else {
            return .failed
        }
        stored = data
        return .committed
    }

    func removeStaging(_ staging: DiagnosticEvidenceStagingHandle) {
        staged.removeValue(forKey: staging.token)
    }
}

internal actor DiagnosticEvidenceStore {
    private let bytesStore: any DiagnosticEvidenceBytesStoring
    private let now: @Sendable () -> Date
    private var persistenceFailed = false

    init(
        bytesStore: any DiagnosticEvidenceBytesStoring,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.bytesStore = bytesStore
        self.now = now
    }

    init(
        applicationSupportBaseURL: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            bytesStore: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: applicationSupportBaseURL),
            now: now
        )
    }

    func record(_ code: DiagnosticEvidenceCode, at time: Date) -> DiagnosticEvidenceRecordResult {
        let currentTime = now()
        if time.timeIntervalSince1970 < 0 || time > currentTime {
            return .unavailable
        }

        let intended: DiagnosticEvidenceEnvelope
        switch bytesStore.readCanonical() {
        case .failed:
            persistenceFailed = true
            return .unavailable
        case .absent:
            var envelope = DiagnosticEvidenceEnvelope(
                schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
                entries: []
            )
            envelope.incorporating(code: code, at: time)
            intended = envelope
        case .bytes(let data):
            if var envelope = try? DiagnosticEvidenceEnvelope.decoded(from: data, now: currentTime) {
                envelope = envelope.pruned(now: currentTime)
                envelope.incorporating(code: code, at: time)
                intended = envelope
            } else {
                intended = DiagnosticEvidenceEnvelope(
                    schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
                    entries: [
                        DiagnosticEvidenceEntry(code: code, firstAt: time, lastAt: time, repeatCount: 1)
                    ]
                )
            }
        }

        return persist(intended, now: currentTime, asRecord: true)
    }

    func read() -> DiagnosticEvidenceRead {
        if persistenceFailed {
            return .unavailable
        }
        let currentTime = now()

        switch bytesStore.readCanonical() {
        case .failed:
            persistenceFailed = true
            return .unavailable
        case .absent:
            return .available(
                DiagnosticEvidenceEnvelope(
                    schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
                    entries: []
                )
            )
        case .bytes(let data):
            guard let envelope = try? DiagnosticEvidenceEnvelope.decoded(from: data, now: currentTime) else {
                persistenceFailed = true
                return .unavailable
            }
            let pruned = envelope.pruned(now: currentTime)
            if pruned.entries == envelope.entries {
                return .available(envelope)
            }
            switch persist(pruned, now: currentTime, asRecord: false) {
            case .recorded:
                return .available(pruned)
            case .unavailable:
                return .unavailable
            }
        }
    }

    private func persist(
        _ intended: DiagnosticEvidenceEnvelope,
        now currentTime: Date,
        asRecord: Bool
    ) -> DiagnosticEvidenceRecordResult {
        let encoded: Data
        switch bytesStore.encode(intended) {
        case .encoded(let data):
            encoded = data
        case .failed:
            return unavailable()
        }

        let staging: DiagnosticEvidenceStagingHandle
        switch bytesStore.stage(encoded) {
        case .staged(let handle):
            staging = handle
        case .failed:
            return unavailable()
        }

        switch bytesStore.readStaged(staging) {
        case .bytes(let data):
            // Staged bytes must be identical to the `Data` this call's trusted encoder returned and strictly readable at `currentTime`; in-memory Date equality is not transport integrity because `.secondsSince1970` / `Date(timeIntervalSince1970:)` can shift live timestamps by one ULP.
            guard data == encoded,
                  (try? DiagnosticEvidenceEnvelope.decoded(from: data, now: currentTime)) != nil else {
                return unavailable(after: staging)
            }
        case .absent, .failed:
            return unavailable(after: staging)
        }

        guard bytesStore.commit(staging) == .committed else {
            return unavailable(after: staging)
        }
        if asRecord {
            persistenceFailed = false
        }
        return .recorded
    }

    private func unavailable() -> DiagnosticEvidenceRecordResult {
        persistenceFailed = true
        return .unavailable
    }

    private func unavailable(after staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceRecordResult {
        persistenceFailed = true
        bytesStore.removeStaging(staging)
        return .unavailable
    }
}

private struct DiagnosticEvidenceAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
}
