// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import Observation
import SPLTunnel
import SolstoneCore

/// Connection freshness is memory-only; a saved observation is always last known on launch.
@MainActor
@Observable
final class JournalVersionMetadata {
    private struct Record: Codable {
        let identity: String
        let version: String
        let name: String?
        let hostBuild: String?
        let hostOS: String?
        let hostOSVersion: String?
        let hostArch: String?
        let versionObservedAt: Date?
        let hostFactsAcceptedAt: Date?

        init(
            identity: String,
            version: String,
            name: String? = nil,
            hostBuild: String? = nil,
            hostOS: String? = nil,
            hostOSVersion: String? = nil,
            hostArch: String? = nil,
            versionObservedAt: Date? = nil,
            hostFactsAcceptedAt: Date? = nil
        ) {
            self.identity = identity
            self.version = version
            self.name = name
            self.hostBuild = hostBuild
            self.hostOS = hostOS
            self.hostOSVersion = hostOSVersion
            self.hostArch = hostArch
            self.versionObservedAt = versionObservedAt
            self.hostFactsAcceptedAt = hostFactsAcceptedAt
        }

        enum CodingKeys: String, CodingKey {
            case identity
            case version
            case name
            case hostBuild = "host_build"
            case hostOS = "host_os"
            case hostOSVersion = "host_os_version"
            case hostArch = "host_arch"
            case versionObservedAt = "version_observed_at"
            case hostFactsAcceptedAt = "host_facts_accepted_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identity = try container.decode(String.self, forKey: .identity)
            version = try container.decode(String.self, forKey: .version)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            hostBuild = try? container.decodeIfPresent(String.self, forKey: .hostBuild)
            hostOS = try? container.decodeIfPresent(String.self, forKey: .hostOS)
            hostOSVersion = try? container.decodeIfPresent(String.self, forKey: .hostOSVersion)
            hostArch = try? container.decodeIfPresent(String.self, forKey: .hostArch)
            versionObservedAt = try? container.decodeIfPresent(Date.self, forKey: .versionObservedAt)
            hostFactsAcceptedAt = try? container.decodeIfPresent(Date.self, forKey: .hostFactsAcceptedAt)
        }
    }

    enum AboutAcceptResult: Equatable {
        case accepted
        case pending
        case mismatch
        case stale
    }

    private struct PendingAbout {
        let identity: String
        let generation: UInt64
        let resource: SolstoneCoreAbout.Resource
    }

    private(set) var version: String?
    private(set) var journalName: String?
    private(set) var isCurrent = false
    private(set) var hostBuild: String?
    private(set) var hostOS: String?
    private(set) var hostOSVersion: String?
    private(set) var hostArch: String?
    private(set) var versionObservedAt: Date?
    private(set) var hostFactsAcceptedAt: Date?
    private(set) var factsGeneration: UInt64 = 0
    @ObservationIgnored var onAboutChanged: (@MainActor @Sendable (Bool) -> Void)?
    var displayValue: String {
        guard let version else { return "unknown" }
        return isCurrent ? version : "\(version) (last known)"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable (Int) async -> String?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activePort: Int?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingAbout: PendingAbout?
    private static let storageKey = "journalVersionMetadata"

    init(defaults: UserDefaults = .standard,
         now: @escaping @Sendable () -> Date = { Date() },
         fetch: @escaping @Sendable (Int) async -> String? = { await JournalVersionStatusClient.fetch(localPort: $0) }) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
    }

    func setIdentity(_ value: String?) {
        guard identity != value else {
            if value == nil { clear() }
            return
        }
        bumpGeneration()
        identity = value
        version = nil
        journalName = nil
        clearFacts()
        versionObservedAt = nil
        hostFactsAcceptedAt = nil
        if let value, let data = defaults.data(forKey: Self.storageKey),
           let record = try? JSONDecoder().decode(Record.self, from: data),
           record.identity == value, let saved = sanitizedJournalVersion(record.version) {
            version = saved
            journalName = record.name.flatMap(sanitizedJournalName)
            hostBuild = record.hostBuild
            hostOS = record.hostOS
            hostOSVersion = record.hostOSVersion
            hostArch = record.hostArch
            versionObservedAt = record.versionObservedAt
            hostFactsAcceptedAt = record.hostFactsAcceptedAt
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
        notifyAboutChanged(factsAccepted: false)
    }

    func clear() {
        bumpGeneration()
        identity = nil
        version = nil
        journalName = nil
        clearFacts()
        versionObservedAt = nil
        defaults.removeObject(forKey: Self.storageKey)
        notifyAboutChanged(factsAccepted: false)
    }

    func disconnected() {
        bumpGeneration()
        notifyAboutChanged(factsAccepted: false)
    }

    private func bumpGeneration() {
        generation &+= 1
        activePort = nil
        isCurrent = false
        pendingAbout = nil
        task?.cancel()
        task = nil
    }

    func currentGeneration() -> UInt64 {
        generation
    }

    func adoptConnectedPort(_ localPort: Int) {
        activePort = localPort
    }

    @discardableResult
    func applyDirectly(
        identity: String,
        generation expectedGeneration: UInt64? = nil,
        version: String?,
        name: String?,
        markCurrent: Bool = true,
        preserveName: Bool = false
    ) -> AboutAcceptResult? {
        guard self.identity == identity else { return .stale }
        if let expectedGeneration, self.generation != expectedGeneration { return .stale }
        let acceptedVersion = version.flatMap(sanitizedJournalVersion)
        let currentVersion = acceptedVersion ?? self.version
        let currentName = preserveName ? self.journalName : name.flatMap(sanitizedJournalName)

        if let currentVersion {
            let changed = self.version != currentVersion
            if changed {
                clearFacts()
            }
            self.version = currentVersion
            self.journalName = currentName
            self.isCurrent = markCurrent
            self.versionObservedAt = now()

            persistRecord(identity: identity)
            notifyAboutChanged(factsAccepted: false)

            var aboutResult: AboutAcceptResult?
            if let pendingAbout {
                self.pendingAbout = nil
                if Self.versionsMatch(pendingAbout.resource.version, currentVersion) {
                    aboutResult = commitFacts(pendingAbout.resource, identity: identity, generation: expectedGeneration ?? self.generation)
                } else {
                    aboutResult = .mismatch
                }
            }
            return aboutResult
        }
        return nil
    }

    func receiveAbout(
        _ resource: SolstoneCoreAbout.Resource,
        identity: String,
        generation expectedGeneration: UInt64
    ) -> AboutAcceptResult {
        guard self.identity == identity, generation == expectedGeneration else { return .stale }
        guard SolstoneCoreAbout.renderLine(
            name: "journal",
            version: resource.version,
            build: resource.build,
            os: resource.os,
            osVersion: resource.osVersion,
            arch: resource.arch
        ) == resource.about else { return .mismatch }

        guard let version else {
            pendingAbout = PendingAbout(identity: identity, generation: expectedGeneration, resource: resource)
            return .pending
        }
        guard Self.versionsMatch(resource.version, version) else { return .mismatch }
        return commitFacts(resource, identity: identity, generation: expectedGeneration)
    }

    func ownerFacingJournalLine(now date: Date) -> String {
        guard let version else { return "journal unknown" }
        let hasObservation = versionObservedAt != nil
        let age: String? = {
            guard !isCurrent, let versionObservedAt, versionObservedAt <= date else { return nil }
            return coarseRelativeTime(versionObservedAt, now: date)
        }()
        return SolstoneCoreAbout.renderLine(
            name: "journal",
            version: version,
            build: hasObservation ? hostBuild : nil,
            os: hasObservation ? hostOS : nil,
            osVersion: hasObservation ? hostOSVersion : nil,
            arch: hasObservation ? hostArch : nil,
            age: age
        )
    }

    func nativeAboutSnapshot(os: String, osVersion: String, arch: String?) -> SolstoneCoreAbout.NativeSnapshot {
        SolstoneCoreAbout.nativeSnapshot(
            os: os,
            osVersion: osVersion,
            arch: arch,
            journalVersion: version,
            journalBuild: hostBuild,
            journalOS: hostOS,
            journalOSVersion: hostOSVersion,
            journalArch: hostArch,
            journalCurrent: isCurrent,
            versionObservedAt: versionObservedAt
        )
    }

    private static func versionsMatch(_ lhs: String, _ rhs: String) -> Bool {
        func stripped(_ value: String) -> Substring { value.drop(while: { $0 == "v" }) }
        return stripped(lhs) == stripped(rhs)
    }

    @discardableResult
    private func commitFacts(
        _ resource: SolstoneCoreAbout.Resource,
        identity: String,
        generation expectedGeneration: UInt64
    ) -> AboutAcceptResult {
        guard self.identity == identity, generation == expectedGeneration else { return .stale }
        guard let version, Self.versionsMatch(resource.version, version),
              SolstoneCoreAbout.renderLine(
                name: "journal", version: resource.version, build: resource.build,
                os: resource.os, osVersion: resource.osVersion, arch: resource.arch
              ) == resource.about else { return .mismatch }
        hostBuild = resource.build
        hostOS = resource.os
        hostOSVersion = resource.osVersion
        hostArch = resource.arch
        hostFactsAcceptedAt = now()
        factsGeneration &+= 1
        persistRecord(identity: identity)
        notifyAboutChanged(factsAccepted: true)
        return .accepted
    }

    private func clearFacts() {
        hostBuild = nil
        hostOS = nil
        hostOSVersion = nil
        hostArch = nil
        hostFactsAcceptedAt = nil
    }

    private func persistRecord(identity: String) {
        guard let version else { return }
        let record = Record(
            identity: identity,
            version: version,
            name: journalName,
            hostBuild: hostBuild,
            hostOS: hostOS,
            hostOSVersion: hostOSVersion,
            hostArch: hostArch,
            versionObservedAt: versionObservedAt,
            hostFactsAcceptedAt: hostFactsAcceptedAt
        )
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func notifyAboutChanged(factsAccepted: Bool) {
        onAboutChanged?(factsAccepted)
    }

    @discardableResult
    func connected(localPort: Int) -> Task<Void, Never>? {
        guard let identity, activePort != localPort else { return task }
        bumpGeneration()
        activePort = localPort
        notifyAboutChanged(factsAccepted: false)
        let expectedGeneration = generation
        let fetch = self.fetch
        let request = Task { @MainActor [weak self] in
            let result = await fetch(localPort)
            guard let self, self.generation == expectedGeneration,
                  self.identity == identity, self.activePort == localPort,
                  let result, let version = sanitizedJournalVersion(result) else { return }
            self.applyDirectly(identity: identity, version: version, name: nil, markCurrent: true, preserveName: true)
        }
        task = request
        return request
    }
}

enum JournalVersionStatusClient {
    static func fetch(
        localPort: Int,
        session: URLSession = BoundedLoopbackClient.sharedSession,
        deadline: Duration = .seconds(5)
    ) async -> String? {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/api/system/status"),
              deadline > .zero
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.attachLoopbackCapability()
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

/// Names the journal a pairing reaches, the same across re-pairs to that journal:
/// its instance and its CA chain, never this device's per-pairing certificate.
internal func journalMarkConfirmationIdentity(for pairing: StoredPairing) -> String {
    opaqueSHA256([
        "journal-mark-confirmation-v1",
        pairing.instanceID,
        normalizedCAFingerprint(for: pairing.caChainPEM) ?? pairing.caChainPEM
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
