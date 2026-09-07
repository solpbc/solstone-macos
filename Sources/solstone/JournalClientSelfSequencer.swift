// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

public struct ClientSelfJournalMetadata: Decodable, Sendable {
    public let name: String?
    public let version: String?
    public let ownerLabel: String?

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case ownerLabel = "owner_label"
    }
}

public struct ClientSelfGetResponse: Decodable, Sendable {
    public let protocolVersion: Int
    public let revision: Int
    public let journal: ClientSelfJournalMetadata?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case revision
        case journal
    }
}

public struct ClientSelfPutResponse: Decodable, Sendable {
    public let protocolVersion: Int
    public let revision: Int
    public let journal: ClientSelfJournalMetadata?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case revision
        case journal
    }
}

private struct ClientSelfPutPayload: Encodable {
    let protocolVersion: Int
    let expectedRevision: Int
    let reported: ReportedPayload

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case expectedRevision = "expected_revision"
        case reported
    }

    struct ReportedPayload: Encodable {
        let name: String?
        let platform: String?
        let deviceType: String?
        let appID: String?
        let appVersion: String?

        enum CodingKeys: String, CodingKey {
            case name
            case platform
            case deviceType = "device_type"
            case appID = "app_id"
            case appVersion = "app_version"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(platform, forKey: .platform)
            try container.encode(deviceType, forKey: .deviceType)
            try container.encode(appID, forKey: .appID)
            try container.encode(appVersion, forKey: .appVersion)
        }
    }
}

public struct ClientSelfReportedSnapshot: Equatable, Sendable {
    public let name: String?
    public let platform: String?
    public let deviceType: String?
    public let appID: String?
    public let appVersion: String?

    public init(
        name: String? = nil,
        platform: String? = "macos",
        deviceType: String? = "desktop",
        appID: String? = nil,
        appVersion: String? = nil
    ) {
        self.name = name
        self.platform = platform
        self.deviceType = deviceType
        self.appID = appID
        self.appVersion = appVersion
    }

    public static func sampleCurrent() -> ClientSelfReportedSnapshot {
        // Hostname changes are picked up on the next connection-lifecycle trigger.
        let rawName = Host.current().localizedName
        let rawAppID = Bundle.main.bundleIdentifier ?? SolstoneIdentity.bundleIdentifier
        let rawAppVersion = AppVersion.short

        return ClientSelfReportedSnapshot(
            name: rawName,
            platform: "macos",
            deviceType: "desktop",
            appID: rawAppID,
            appVersion: rawAppVersion
        )
    }

    public func sanitized() -> ClientSelfReportedSnapshot {
        ClientSelfReportedSnapshot(
            name: Self.sanitizeField(name, maxBytes: 80),
            platform: Self.sanitizeField(platform, maxBytes: 64),
            deviceType: Self.sanitizeField(deviceType, maxBytes: 64),
            appID: Self.sanitizeField(appID, maxBytes: 64),
            appVersion: Self.sanitizeField(appVersion, maxBytes: 64)
        )
    }

    public static func sanitizeField(_ raw: String?, maxBytes: Int) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { scalar in
            scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value) || CharacterSet.newlines.contains(scalar)
        }) else { return nil }
        guard trimmed.utf8.count <= maxBytes else { return nil }
        return trimmed
    }
}

public actor JournalClientSelfSequencer {
    public struct TargetConnection: Equatable, Sendable {
        public let localPort: Int
        public let identity: String
        public let pairingGeneration: UInt64
        public let metadataGeneration: UInt64

        public init(localPort: Int, identity: String, pairingGeneration: UInt64, metadataGeneration: UInt64) {
            self.localPort = localPort
            self.identity = identity
            self.pairingGeneration = pairingGeneration
            self.metadataGeneration = metadataGeneration
        }
    }

    private enum PutOutcome {
        case success
        case conflict
        case failure
    }

    private let session: URLSession
    private let deadline: Duration
    private let onJournalMetadataUpdated: @Sendable (String, UInt64, String?, String?) async -> Void

    private var activeTarget: TargetConnection?
    private var inFlight = false
    private var pendingSnapshot: ClientSelfReportedSnapshot?
    private var jobGeneration: UInt64 = 0

    public init(
        session: URLSession = BoundedLoopbackClient.makeSession(),
        deadline: Duration = BoundedLoopbackClient.defaultDeadline,
        onJournalMetadataUpdated: @escaping @Sendable (String, UInt64, String?, String?) async -> Void
    ) {
        self.session = session
        self.deadline = deadline
        self.onJournalMetadataUpdated = onJournalMetadataUpdated
    }

    public var isBusy: Bool {
        inFlight
    }

    public func enqueue(
        target: TargetConnection,
        snapshot: ClientSelfReportedSnapshot = .sampleCurrent()
    ) {
        if activeTarget != target {
            activeTarget = target
            jobGeneration &+= 1
        }
        pendingSnapshot = snapshot
        drainIfNeeded()
    }

    public func cancel() {
        activeTarget = nil
        pendingSnapshot = nil
        jobGeneration &+= 1
    }

    private func drainIfNeeded() {
        guard !inFlight, let target = activeTarget, let snapshot = pendingSnapshot else { return }
        inFlight = true
        pendingSnapshot = nil
        let currentJobGen = jobGeneration

        Task {
            await self.runJob(target: target, snapshot: snapshot, jobGen: currentJobGen)
        }
    }

    private func runJob(
        target: TargetConnection,
        snapshot: ClientSelfReportedSnapshot,
        jobGen: UInt64
    ) async {
        defer {
            inFlight = false
            drainIfNeeded()
        }

        guard activeTarget == target, jobGeneration == jobGen else { return }

        do {
            try await performPublication(target: target, snapshot: snapshot, jobGen: jobGen)
        } catch {
            Logger.journal.error("ClientSelf publication failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performPublication(
        target: TargetConnection,
        snapshot: ClientSelfReportedSnapshot,
        jobGen: UInt64
    ) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(target.localPort)/app/network/api/clients/self") else {
            return
        }

        var getReq = URLRequest(url: url)
        getReq.httpMethod = "GET"
        getReq.setValue("application/json", forHTTPHeaderField: "Accept")

        let (getData, getResp): (Data, HTTPURLResponse)
        do {
            (getData, getResp) = try await BoundedLoopbackClient.execute(
                request: getReq,
                session: session,
                deadline: deadline
            )
        } catch {
            return
        }

        guard activeTarget == target, jobGeneration == jobGen else { return }

        if getResp.statusCode == 404 {
            if let fallbackVersion = await JournalVersionStatusClient.fetch(localPort: target.localPort) {
                guard activeTarget == target, jobGeneration == jobGen else { return }
                await onJournalMetadataUpdated(target.identity, target.metadataGeneration, fallbackVersion, nil)
            }
            return
        }

        guard getResp.statusCode == 200 else { return }

        guard let getResponse = try? JSONDecoder().decode(ClientSelfGetResponse.self, from: getData),
              getResponse.protocolVersion == 1,
              getResponse.revision >= 0
        else {
            return
        }

        if let journal = getResponse.journal {
            await onJournalMetadataUpdated(target.identity, target.metadataGeneration, journal.version, journal.name)
        }

        let currentSnapshot = pendingSnapshot ?? snapshot
        pendingSnapshot = nil
        let putOutcome = try await sendPut(
            url: url,
            expectedRevision: getResponse.revision,
            snapshot: currentSnapshot,
            target: target,
            jobGen: jobGen
        )

        if putOutcome == .conflict {
            guard activeTarget == target, jobGeneration == jobGen else { return }
            let (retryData, retryResp) = try await BoundedLoopbackClient.execute(
                request: getReq,
                session: session,
                deadline: deadline
            )
            guard retryResp.statusCode == 200,
                  let retryResponse = try? JSONDecoder().decode(ClientSelfGetResponse.self, from: retryData),
                  retryResponse.protocolVersion == 1,
                  retryResponse.revision >= 0
            else { return }

            if let journal = retryResponse.journal {
                await onJournalMetadataUpdated(target.identity, target.metadataGeneration, journal.version, journal.name)
            }

            let latestSnapshot = pendingSnapshot ?? ClientSelfReportedSnapshot.sampleCurrent()
            pendingSnapshot = nil
            _ = try await sendPut(
                url: url,
                expectedRevision: retryResponse.revision,
                snapshot: latestSnapshot,
                target: target,
                jobGen: jobGen
            )
        }
    }

    private func sendPut(
        url: URL,
        expectedRevision: Int,
        snapshot: ClientSelfReportedSnapshot,
        target: TargetConnection,
        jobGen: UInt64
    ) async throws -> PutOutcome {
        guard activeTarget == target, jobGeneration == jobGen else { return .failure }
        let sanitized = snapshot.sanitized()

        let payload = ClientSelfPutPayload(
            protocolVersion: 1,
            expectedRevision: expectedRevision,
            reported: ClientSelfPutPayload.ReportedPayload(
                name: sanitized.name,
                platform: sanitized.platform,
                deviceType: sanitized.deviceType,
                appID: sanitized.appID,
                appVersion: sanitized.appVersion
            )
        )

        let bodyData = try JSONEncoder().encode(payload)
        var putReq = URLRequest(url: url)
        putReq.httpMethod = "PUT"
        putReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putReq.setValue("application/json", forHTTPHeaderField: "Accept")
        putReq.httpBody = bodyData

        let (putData, putResp) = try await BoundedLoopbackClient.execute(
            request: putReq,
            session: session,
            deadline: deadline
        )

        guard activeTarget == target, jobGeneration == jobGen else { return .failure }

        if putResp.statusCode == 200 {
            if let putResponse = try? JSONDecoder().decode(ClientSelfPutResponse.self, from: putData),
               let journal = putResponse.journal {
                await onJournalMetadataUpdated(target.identity, target.metadataGeneration, journal.version, journal.name)
            }
            return .success
        }

        if putResp.statusCode == 409 {
            return .conflict
        }

        return .failure
    }
}
