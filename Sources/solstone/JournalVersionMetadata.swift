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
    }

    private(set) var version: String?
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
         fetch: @escaping @Sendable (Int) async -> String? = JournalVersionStatusClient.fetch) {
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
        if let value, let data = defaults.data(forKey: Self.storageKey),
           let record = try? JSONDecoder().decode(Record.self, from: data),
           record.identity == value, let saved = sanitizedJournalVersion(record.version) {
            version = saved
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    func clear() {
        disconnected()
        identity = nil
        version = nil
        defaults.removeObject(forKey: Self.storageKey)
    }

    func disconnected() {
        generation &+= 1
        activePort = nil
        isCurrent = false
        task?.cancel()
        task = nil
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
            // Validation and persistence share this actor turn with pairing/lifecycle changes.
            if let data = try? JSONEncoder().encode(Record(identity: identity, version: version)) {
                self.defaults.set(data, forKey: Self.storageKey)
            }
            self.version = version
            self.isCurrent = true
        }
        task = request
        return request
    }
}

private final class JournalVersionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum JournalVersionStatusClient {
    static func fetch(localPort: Int) async -> String? {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/api/system/status") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration,
                                 delegate: JournalVersionRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
            return sanitizedJournalVersion(status.version.current)
        } catch { return nil }
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
