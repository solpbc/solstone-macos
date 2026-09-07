// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SPLTunnel

public actor JournalRelayAccessSequencer {
    public struct TargetConnection: Equatable, Sendable {
        public let localPort: Int
        public let instanceID: String
        public let pairingGeneration: UInt64
        public let accessMutationGeneration: UInt64

        public init(
            localPort: Int,
            instanceID: String,
            pairingGeneration: UInt64,
            accessMutationGeneration: UInt64
        ) {
            self.localPort = localPort
            self.instanceID = instanceID
            self.pairingGeneration = pairingGeneration
            self.accessMutationGeneration = accessMutationGeneration
        }
    }

    public enum AccessUpdateOutcome: Sendable {
        case ready(StoredPairing)
        case notConfiguredLiveDisabled
        case durableClearPersisted
        case durableClearFailed(pairingGen: UInt64, accessGen: UInt64)
        case ignored
    }

    private let session: URLSession
    private let deadline: Duration
    private let credentialStore: PairingCredentialStore
    private let onOutcome: @Sendable (AccessUpdateOutcome) async -> Void

    private var activeTarget: TargetConnection?
    private var inFlight = false
    private var hasPendingTrigger = false
    private var jobGeneration: UInt64 = 0

    public init(
        credentialStore: PairingCredentialStore,
        session: URLSession = BoundedLoopbackClient.makeSession(),
        deadline: Duration = BoundedLoopbackClient.defaultDeadline,
        onOutcome: @escaping @Sendable (AccessUpdateOutcome) async -> Void
    ) {
        self.credentialStore = credentialStore
        self.session = session
        self.deadline = deadline
        self.onOutcome = onOutcome
    }

    public var isBusy: Bool {
        inFlight
    }

    public func enqueue(target: TargetConnection) {
        if activeTarget != target {
            activeTarget = target
            jobGeneration &+= 1
        }
        hasPendingTrigger = true
        drainIfNeeded()
    }

    public func cancel() {
        activeTarget = nil
        hasPendingTrigger = false
        jobGeneration &+= 1
    }

    private func drainIfNeeded() {
        guard !inFlight, let target = activeTarget, hasPendingTrigger else { return }
        inFlight = true
        hasPendingTrigger = false
        let currentJobGen = jobGeneration

        Task {
            await self.runJob(target: target, jobGen: currentJobGen)
        }
    }

    private func runJob(target: TargetConnection, jobGen: UInt64) async {
        defer {
            inFlight = false
            drainIfNeeded()
        }

        guard activeTarget == target, jobGeneration == jobGen else { return }

        guard let url = URL(string: "http://127.0.0.1:\(target.localPort)/app/network/api/relay/access") else {
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await BoundedLoopbackClient.execute(
                request: req,
                session: session,
                deadline: deadline
            )
        } catch {
            Logger.journal.error("Relay access fetch error: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard activeTarget == target, jobGeneration == jobGen else { return }
        guard response.statusCode == 200 else { return }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let protocolVersion = (json["protocol_version"] as? NSNumber)?.intValue ?? (json["protocol_version"] as? Int)
        guard protocolVersion == 2,
              let status = json["status"] as? String
        else {
            return
        }

        if status == "not_configured" {
            guard Set(json.keys) == Set(["protocol_version", "status"]) else {
                return
            }

            guard activeTarget == target, jobGeneration == jobGen else { return }
            await onOutcome(.notConfiguredLiveDisabled)

            guard activeTarget == target, jobGeneration == jobGen else { return }
            do {
                _ = try credentialStore.clearRelayAccess(
                    expectedPairingGen: target.pairingGeneration,
                    expectedAccessGen: target.accessMutationGeneration
                )
                guard activeTarget == target, jobGeneration == jobGen else { return }
                await onOutcome(.durableClearPersisted)
            } catch {
                Logger.journal.error("Durable clear save error: \(error.localizedDescription, privacy: .public)")
                guard activeTarget == target, jobGeneration == jobGen else { return }
                await onOutcome(.durableClearFailed(
                    pairingGen: target.pairingGeneration,
                    accessGen: target.accessMutationGeneration
                ))
            }
            return
        }

        if status == "ready" {
            guard let relayOrigin = json["relay_origin"] as? String,
                  let instanceID = json["instance_id"] as? String,
                  let deviceToken = json["device_token"] as? String,
                  let expiresAtString = json["expires_at"] as? String
            else {
                return
            }

            let validated: ValidatedRelayAccess
            do {
                validated = try JournalRelayAccessValidator.validateReadyResponse(
                    protocolVersion: protocolVersion ?? 2,
                    status: status,
                    relayOrigin: relayOrigin,
                    instanceID: instanceID,
                    deviceToken: deviceToken,
                    expiresAtString: expiresAtString,
                    pairedInstanceID: target.instanceID
                )
            } catch {
                Logger.journal.error("Relay access validation failed: \(error.localizedDescription, privacy: .public)")
                return
            }

            guard activeTarget == target, jobGeneration == jobGen else { return }

            do {
                let (updatedPairing, _) = try credentialStore.updateRelayAccess(
                    expectedPairingGen: target.pairingGeneration,
                    expectedAccessGen: target.accessMutationGeneration,
                    relayOrigin: validated.relayOrigin,
                    deviceToken: validated.deviceToken,
                    expiresAtString: validated.expiresAtString
                )
                guard activeTarget == target, jobGeneration == jobGen else { return }
                await onOutcome(.ready(updatedPairing))
            } catch {
                Logger.journal.error("Failed to persist updated relay access: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
