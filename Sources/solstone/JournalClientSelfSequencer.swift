// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Synchronization
import os
import SolstoneCore

public struct ClientSelfJournalMetadata: Decodable, Sendable {
    public let name: String?
    public let version: String

    enum CodingKeys: String, CodingKey {
        case name
        case version
    }

    public init(name: String?, version: String) {
        self.name = name
        self.version = version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String?.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
    }
}

public struct ClientSelfReportedPayload: Decodable, Sendable {
    public let name: String?
    public let platform: String?
    public let deviceType: String?
    public let appID: String?
    public let appVersion: String?

    enum CodingKeys: String, CodingKey {
        case name
        case platform
        case deviceType = "device_type"
        case appID = "app_id"
        case appVersion = "app_version"
    }

    public init(name: String?, platform: String?, deviceType: String?, appID: String?, appVersion: String?) {
        self.name = name
        self.platform = platform
        self.deviceType = deviceType
        self.appID = appID
        self.appVersion = appVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String?.self, forKey: .name)
        platform = try container.decode(String?.self, forKey: .platform)
        deviceType = try container.decode(String?.self, forKey: .deviceType)
        appID = try container.decode(String?.self, forKey: .appID)
        appVersion = try container.decode(String?.self, forKey: .appVersion)
    }
}

public struct ClientSelfProtocol1Response: Decodable, Sendable {
    public let protocolVersion: Int
    public let revision: UInt64
    public let journal: ClientSelfJournalMetadata
    public let reported: ClientSelfReportedPayload?
    public let ownerLabel: String?
    public let displayLabel: String
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case revision
        case journal
        case reported
        case ownerLabel = "owner_label"
        case displayLabel = "display_label"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .protocolVersion, in: container, debugDescription: "Expected protocol_version == 1")
        }
        revision = try container.decode(UInt64.self, forKey: .revision)
        journal = try container.decode(ClientSelfJournalMetadata.self, forKey: .journal)
        reported = try container.decode(ClientSelfReportedPayload?.self, forKey: .reported)
        ownerLabel = try container.decode(String?.self, forKey: .ownerLabel)
        displayLabel = try container.decode(String.self, forKey: .displayLabel)
        updatedAt = try container.decode(String?.self, forKey: .updatedAt)
    }
}

public typealias ClientSelfGetResponse = ClientSelfProtocol1Response
public typealias ClientSelfPutResponse = ClientSelfProtocol1Response

public enum ClientSelfProtocol1Validator {
    public static func decode(_ data: Data) -> ClientSelfProtocol1Response? {
        guard data.count <= 65536 else { return nil }
        guard let decoded = try? JSONDecoder().decode(ClientSelfProtocol1Response.self, from: data) else {
            return nil
        }
        guard decoded.protocolVersion == 1,
              sanitizedJournalVersion(decoded.journal.version) != nil else { return nil }
        if let name = decoded.journal.name, sanitizedJournalName(name) == nil { return nil }
        return decoded
    }
}

private struct ClientSelfPutPayload: Encodable {
    let protocolVersion: Int
    let expectedRevision: UInt64
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

public final class MetadataPublicationFence: Sendable {
    private let current = Mutex(true)

    public func withCurrent(_ action: () -> Void) {
        current.withLock { isCurrent in
            if isCurrent { action() }
        }
    }

    fileprivate func invalidate() {
        current.withLock { $0 = false }
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
    private let onJournalMetadataUpdated: @Sendable (String, UInt64, String?, String?, Bool, ContinuousClock.Instant, MetadataPublicationFence) async -> Void

    private var activeTarget: TargetConnection?
    private var inFlight = false
    private var pendingSnapshot: ClientSelfReportedSnapshot?
    private var jobGeneration: UInt64 = 0
    private var activeBurstID: UInt64?
    private var passesStarted = 0
    private var publicationFence: MetadataPublicationFence?

    public init(
        session: URLSession = BoundedLoopbackClient.sharedSession,
        deadline: Duration = BoundedLoopbackClient.defaultDeadline,
        onJournalMetadataUpdated: @escaping @Sendable (String, UInt64, String?, String?, Bool, ContinuousClock.Instant, MetadataPublicationFence) async -> Void
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
        snapshot: ClientSelfReportedSnapshot = .sampleCurrent(),
        burstID: UInt64? = nil
    ) {
        let requestedBurst = burstID ?? ((!inFlight || activeTarget?.pairingGeneration != target.pairingGeneration)
            ? (activeBurstID ?? 0) &+ 1 : (activeBurstID ?? 1))
        if let activeBurstID, requestedBurst < activeBurstID { return }
        if activeBurstID != requestedBurst {
            publicationFence?.invalidate()
            activeBurstID = requestedBurst
            passesStarted = 0
            jobGeneration &+= 1
        }
        if activeTarget != target {
            publicationFence?.invalidate()
            activeTarget = target
            jobGeneration &+= 1
        }
        pendingSnapshot = snapshot
        drainIfNeeded()
    }

    public func cancel() {
        publicationFence?.invalidate()
        activeTarget = nil
        pendingSnapshot = nil
        activeBurstID = nil
        passesStarted = 0
        jobGeneration &+= 1
    }

    private func drainIfNeeded() {
        guard !inFlight, passesStarted < 2, let target = activeTarget, let snapshot = pendingSnapshot else { return }
        passesStarted += 1
        inFlight = true
        pendingSnapshot = nil
        let currentJobGen = jobGeneration
        let fence = MetadataPublicationFence()
        publicationFence = fence

        Task {
            await self.runJob(target: target, snapshot: snapshot, jobGen: currentJobGen, fence: fence)
        }
    }

    private func runJob(
        target: TargetConnection,
        snapshot: ClientSelfReportedSnapshot,
        jobGen: UInt64,
        fence: MetadataPublicationFence
    ) async {
        defer {
            fence.invalidate()
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

        let jobDeadline = ContinuousClock.now + deadline
        let getRemaining = jobDeadline - ContinuousClock.now
        guard getRemaining > .zero else { return }

        var getReq = URLRequest(url: url)
        getReq.httpMethod = "GET"
        getReq.setValue("application/json", forHTTPHeaderField: "Accept")

        let (getData, getResp): (Data, HTTPURLResponse)
        do {
            (getData, getResp) = try await BoundedLoopbackClient.execute(
                request: getReq,
                session: session,
                deadline: getRemaining
            )
        } catch {
            return
        }

        guard activeTarget == target, jobGeneration == jobGen else { return }

        if getResp.statusCode == 404 {
            let fallbackRemaining = jobDeadline - ContinuousClock.now
            guard fallbackRemaining > .zero else { return }
            if let fallbackVersion = await JournalVersionStatusClient.fetch(
                localPort: target.localPort,
                session: session,
                deadline: fallbackRemaining
            ) {
                guard activeTarget == target, jobGeneration == jobGen else { return }
                await publishMetadata(target: target, jobGen: jobGen, version: fallbackVersion, name: nil, preserveName: true, jobDeadline: jobDeadline)
            }
            return
        }

        guard getResp.statusCode == 200 else { return }

        guard let getResponse = ClientSelfProtocol1Validator.decode(getData) else {
            return
        }

        guard activeTarget == target, jobGeneration == jobGen else { return }

        await publishMetadata(target: target, jobGen: jobGen, version: getResponse.journal.version, name: getResponse.journal.name, preserveName: false, jobDeadline: jobDeadline)

        guard activeTarget == target, jobGeneration == jobGen else { return }

        let currentSnapshot = pendingSnapshot ?? snapshot
        pendingSnapshot = nil
        let putRemaining = jobDeadline - ContinuousClock.now
        guard putRemaining > .zero else { return }

        let putOutcome = try await sendPut(
            url: url,
            expectedRevision: getResponse.revision,
            snapshot: currentSnapshot,
            target: target,
            jobGen: jobGen,
            deadline: putRemaining,
            jobDeadline: jobDeadline
        )

        if putOutcome == .conflict {
            guard activeTarget == target, jobGeneration == jobGen else { return }
            let retryGetRemaining = jobDeadline - ContinuousClock.now
            guard retryGetRemaining > .zero else { return }

            let (retryData, retryResp) = try await BoundedLoopbackClient.execute(
                request: getReq,
                session: session,
                deadline: retryGetRemaining
            )
            guard retryResp.statusCode == 200,
                  let retryResponse = ClientSelfProtocol1Validator.decode(retryData)
            else { return }

            guard activeTarget == target, jobGeneration == jobGen else { return }

            await publishMetadata(target: target, jobGen: jobGen, version: retryResponse.journal.version, name: retryResponse.journal.name, preserveName: false, jobDeadline: jobDeadline)

            guard activeTarget == target, jobGeneration == jobGen else { return }
            let latestSnapshot = pendingSnapshot ?? ClientSelfReportedSnapshot.sampleCurrent()
            pendingSnapshot = nil
            let retryPutRemaining = jobDeadline - ContinuousClock.now
            guard retryPutRemaining > .zero else { return }

            _ = try await sendPut(
                url: url,
                expectedRevision: retryResponse.revision,
                snapshot: latestSnapshot,
                target: target,
                jobGen: jobGen,
                deadline: retryPutRemaining,
                jobDeadline: jobDeadline
            )
        }
    }

    private func publishMetadata(
        target: TargetConnection,
        jobGen: UInt64,
        version: String?,
        name: String?,
        preserveName: Bool,
        jobDeadline: ContinuousClock.Instant
    ) async {
        guard activeTarget == target, jobGeneration == jobGen,
              ContinuousClock.now < jobDeadline, let fence = publicationFence else { return }
        let callback = onJournalMetadataUpdated
        let (completion, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // The owner checks the same deadline at its actual cache mutation. A
        // queued callback may outlive this waiter, but cannot publish late.
        let publication = Task {
            await callback(target.identity, target.metadataGeneration, version, name, preserveName, jobDeadline, fence)
            continuation.yield(true)
            continuation.finish()
        }
        let timeout = Task {
            do { try await Task.sleep(until: jobDeadline, clock: .continuous) }
            catch { return }
            fence.invalidate()
            continuation.yield(false)
            continuation.finish()
        }
        var iterator = completion.makeAsyncIterator()
        _ = await iterator.next()
        publication.cancel()
        timeout.cancel()
    }

    private func sendPut(
        url: URL,
        expectedRevision: UInt64,
        snapshot: ClientSelfReportedSnapshot,
        target: TargetConnection,
        jobGen: UInt64,
        deadline: Duration,
        jobDeadline: ContinuousClock.Instant
    ) async throws -> PutOutcome {
        guard activeTarget == target, jobGeneration == jobGen else { return .failure }
        guard deadline > .zero else { return .failure }
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
            guard let putResponse = ClientSelfProtocol1Validator.decode(putData) else {
                // Malformed PUT 200: keep latest validated cache, do not publish invalid journal
                return .success
            }
            guard activeTarget == target, jobGeneration == jobGen else { return .failure }
            await publishMetadata(target: target, jobGen: jobGen, version: putResponse.journal.version, name: putResponse.journal.name, preserveName: false, jobDeadline: jobDeadline)
            return .success
        }

        if putResp.statusCode == 409 {
            return .conflict
        }

        return .failure
    }
}
