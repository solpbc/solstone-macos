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

    public enum AccessUpdateOutcome: Sendable, Equatable {
        case ready(pairing: StoredPairing, pairingGen: UInt64, accessGen: UInt64, newAccessGen: UInt64)
        case notConfiguredLiveDisabled(pairingGen: UInt64, accessGen: UInt64)
        case durableClearPersisted(pairing: StoredPairing, pairingGen: UInt64, accessGen: UInt64, newAccessGen: UInt64)
        case durableClearFailed(pairingGen: UInt64, accessGen: UInt64)
        case ignored
    }

    private let session: URLSession
    private let deadline: Duration
    private let credentialStore: PairingCredentialStore
    private let onOutcome: @Sendable (AccessUpdateOutcome) async -> Void
    private let now: @Sendable () -> Date

    private var activeTarget: TargetConnection?
    private var inFlight = false
    private var hasPendingTrigger = false
    private var jobGeneration: UInt64 = 0

    public init(
        credentialStore: PairingCredentialStore,
        session: URLSession = BoundedLoopbackClient.makeSession(),
        deadline: Duration = BoundedLoopbackClient.defaultDeadline,
        now: @escaping @Sendable () -> Date = { Date() },
        onOutcome: @escaping @Sendable (AccessUpdateOutcome) async -> Void
    ) {
        self.credentialStore = credentialStore
        self.session = session
        self.deadline = deadline
        self.now = now
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

        let jobDeadline = ContinuousClock.now + deadline
        guard activeTarget == target, jobGeneration == jobGen else { return }

        guard let url = URL(string: "http://127.0.0.1:\(target.localPort)/app/network/api/relay/access") else {
            return
        }

        let remaining = jobDeadline - ContinuousClock.now
        guard remaining > .zero else {
            Logger.journal.error("Relay access fetch timed out before start")
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
                deadline: remaining
            )
        } catch {
            Logger.journal.error("Relay access fetch error: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard activeTarget == target, jobGeneration == jobGen else { return }
        guard response.statusCode == 200 else { return }

        let receiptNow = now()
        let decodedStatus: RelayAccessStatus
        do {
            decodedStatus = try RelayAccessValidation.decode(
                data,
                expectedInstanceID: target.instanceID,
                now: receiptNow
            )
        } catch {
            Logger.journal.error("Relay access validation failed: \(String(describing: error), privacy: .public)")
            return
        }

        guard activeTarget == target, jobGeneration == jobGen else { return }

        switch decodedStatus {
        case .notConfigured:
            await onOutcome(.notConfiguredLiveDisabled(
                pairingGen: target.pairingGeneration,
                accessGen: target.accessMutationGeneration
            ))

            guard activeTarget == target, jobGeneration == jobGen else { return }
            do {
                let (clearedPairing, newAccessGen) = try credentialStore.clearRelayAccess(
                    expectedPairingGen: target.pairingGeneration,
                    expectedAccessGen: target.accessMutationGeneration
                )
                guard activeTarget == target, jobGeneration == jobGen else { return }
                await onOutcome(.durableClearPersisted(
                    pairing: clearedPairing,
                    pairingGen: target.pairingGeneration,
                    accessGen: target.accessMutationGeneration,
                    newAccessGen: newAccessGen
                ))
            } catch {
                Logger.journal.error("Durable clear save error: \(error.localizedDescription, privacy: .public)")
                guard activeTarget == target, jobGeneration == jobGen else { return }
                await onOutcome(.durableClearFailed(
                    pairingGen: target.pairingGeneration,
                    accessGen: target.accessMutationGeneration
                ))
            }

        case .ready(let ready):
            do {
                let (updatedPairing, newAccessGen) = try credentialStore.updateRelayAccess(
                    expectedPairingGen: target.pairingGeneration,
                    expectedAccessGen: target.accessMutationGeneration,
                    relayOrigin: ready.relayOrigin.absoluteString,
                    deviceToken: ready.deviceToken,
                    expiresAtString: ready.expiresAt
                )
                guard activeTarget == target, jobGeneration == jobGen else { return }
                await onOutcome(.ready(
                    pairing: updatedPairing,
                    pairingGen: target.pairingGeneration,
                    accessGen: target.accessMutationGeneration,
                    newAccessGen: newAccessGen
                ))
            } catch {
                Logger.journal.error("Failed to persist updated relay access: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
