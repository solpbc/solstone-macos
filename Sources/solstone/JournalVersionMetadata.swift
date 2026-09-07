// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import Observation
import SPLTunnel

/// Connection freshness is memory-only; a saved observation is always last known on launch.
@MainActor
@Observable
final class JournalVersionMetadata {
    private struct Record: Codable {
        let identity: String
        let version: String
        let name: String?

        init(identity: String, version: String, name: String? = nil) {
            self.identity = identity
            self.version = version
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case identity
            case version
            case name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identity = try container.decode(String.self, forKey: .identity)
            version = try container.decode(String.self, forKey: .version)
            name = try container.decodeIfPresent(String.self, forKey: .name)
        }
    }

    private(set) var version: String?
    private(set) var journalName: String?
    private(set) var isCurrent = false
    var displayValue: String {
        guard let version else { return "unknown" }
        return isCurrent ? version : "\(version) (last known)"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable (Int) async -> String?
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activePort: Int?
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let storageKey = "journalVersionMetadata"

    init(defaults: UserDefaults = .standard,
         fetch: @escaping @Sendable (Int) async -> String? = { await JournalVersionStatusClient.fetch(localPort: $0) }) {
        self.defaults = defaults
        self.fetch = fetch
    }

    func setIdentity(_ value: String?) {
        guard identity != value else {
            if value == nil { clear() }
            return
        }
        disconnected()
        identity = value
        version = nil
        journalName = nil
        if let value, let data = defaults.data(forKey: Self.storageKey),
           let record = try? JSONDecoder().decode(Record.self, from: data),
           record.identity == value, let saved = sanitizedJournalVersion(record.version) {
            version = saved
            journalName = record.name.flatMap(sanitizedJournalName)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    func clear() {
        disconnected()
        identity = nil
        version = nil
        journalName = nil
        defaults.removeObject(forKey: Self.storageKey)
    }

    func disconnected() {
        generation &+= 1
        activePort = nil
        isCurrent = false
        task?.cancel()
        task = nil
    }

    func currentGeneration() -> UInt64 {
        generation
    }

    func adoptConnectedPort(_ localPort: Int) {
        activePort = localPort
    }

    func applyDirectly(
        identity: String,
        generation expectedGeneration: UInt64? = nil,
        version: String?,
        name: String?,
        markCurrent: Bool = true
    ) {
        guard self.identity == identity else { return }
        if let expectedGeneration, self.generation != expectedGeneration { return }
        let currentVersion = version.flatMap(sanitizedJournalVersion) ?? self.version
        let currentName = name.flatMap(sanitizedJournalName) ?? self.journalName

        if let currentVersion {
            self.version = currentVersion
            self.journalName = currentName
            self.isCurrent = markCurrent

            if let data = try? JSONEncoder().encode(Record(identity: identity, version: currentVersion, name: currentName)) {
                self.defaults.set(data, forKey: Self.storageKey)
            }
        }
    }

    @discardableResult
    func connected(localPort: Int) -> Task<Void, Never>? {
        guard let identity, activePort != localPort else { return task }
        disconnected()
        activePort = localPort
        let expectedGeneration = generation
        let fetch = self.fetch
        let request = Task { @MainActor [weak self] in
            let result = await fetch(localPort)
            guard let self, self.generation == expectedGeneration,
                  self.identity == identity, self.activePort == localPort,
                  let result, let version = sanitizedJournalVersion(result) else { return }
            self.applyDirectly(identity: identity, version: version, name: self.journalName, markCurrent: true)
        }
        task = request
        return request
    }
}

enum JournalVersionStatusClient {
    static func fetch(
        localPort: Int,
        session: URLSession = BoundedLoopbackClient.makeSession(),
        deadline: Duration = .seconds(5)
    ) async -> String? {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/api/system/status"),
              deadline > .zero
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await BoundedLoopbackClient.execute(
                request: request,
                session: session,
                deadline: deadline
            )
            guard response.statusCode == 200,
                  let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
            return sanitizedJournalVersion(status.version.current)
        } catch {
            return nil
        }
    }

    private struct Status: Decodable {
        struct Version: Decodable { let current: String }
        let version: Version
    }
}

internal func journalVersionMetadataIdentity(for pairing: StoredPairing) -> String? {
    guard let normalizedCAFingerprint = normalizedCAFingerprint(for: pairing.caChainPEM) else {
        return nil
    }
    return opaqueSHA256([
        "journal-version-metadata-v1",
        pairing.instanceID,
        normalizedCAFingerprint
    ])
}

internal func sanitizedJournalVersion(_ value: String) -> String? {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    guard !value.unicodeScalars.contains(where: { scalar in
        scalar.value <= 0x1F ||
            (0x7F...0x9F).contains(scalar.value) ||
            CharacterSet.newlines.contains(scalar)
    }) else {
        return nil
    }
    return value
}

internal func sanitizedJournalName(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.unicodeScalars.contains(where: { scalar in
        scalar.value <= 0x1F ||
            (0x7F...0x9F).contains(scalar.value) ||
            CharacterSet.newlines.contains(scalar)
    }) else {
        return nil
    }
    guard trimmed.utf8.count <= 80 else { return nil }
    return trimmed
}

private func normalizedCAFingerprint(for pem: String) -> String? {
    guard let certificates = try? CertChain.certificates(fromPEM: pem), !certificates.isEmpty else {
        return nil
    }
    let fingerprints = certificates.map(CertChain.sha256Fingerprint(of:))
    return opaqueSHA256(["journal-version-ca-chain-v1"] + fingerprints)
}

private func opaqueSHA256(_ parts: [String]) -> String {
    let canonical = parts.joined(separator: "\u{1F}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
}
