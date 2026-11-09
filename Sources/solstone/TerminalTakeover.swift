// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SPLTunnel

/// The journal's answer to a migration, or `nil` when it could not be reached.
protocol TerminalMigrationTransport: Sendable {
    func sendMigration(serverURL: String, body: String) async -> (status: Int, reason: String?)?
}

struct TerminalLiveMigrationTransport: TerminalMigrationTransport {
    func sendMigration(serverURL: String, body: String) async -> (status: Int, reason: String?)? {
        guard let url = URL(string: "\(serverURL)/app/network/api/clients/self/migration") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.attachLoopbackCapability()
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason_code"] as? String
        return (http.statusCode, reason)
    }
}

/// Moves a consented install forward. Every step is safe to run again, and a
/// retry only ever resends what was first recorded.
actor TerminalTakeoverDriver {
    private static let backoffFirst: TimeInterval = 5
    private static let backoffMax: TimeInterval = 300

    private let store: TerminalTakeoverStore
    private let host: TerminalTakeoverHost
    private let planner: TerminalUploadPlanner
    private let settingsURL: URL
    private let transport: any TerminalMigrationTransport
    private let serverURL: @Sendable () async -> String?
    private let appPairing: @Sendable () async -> TerminalContinuityPlan.AppPairing?
    private let turnTerminalOn: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private var migrationNextAt = Date.distantPast
    private var migrationBackoff = backoffFirst
    private var listedThisRun = false
    private var advancing = false

    init(
        store: TerminalTakeoverStore,
        host: TerminalTakeoverHost,
        planner: TerminalUploadPlanner,
        settingsURL: URL,
        transport: any TerminalMigrationTransport = TerminalLiveMigrationTransport(),
        serverURL: @escaping @Sendable () async -> String?,
        appPairing: @escaping @Sendable () async -> TerminalContinuityPlan.AppPairing?,
        turnTerminalOn: @escaping @Sendable () async -> Void,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.host = host
        self.planner = planner
        self.settingsURL = settingsURL
        self.transport = transport
        self.serverURL = serverURL
        self.appPairing = appPairing
        self.turnTerminalOn = turnTerminalOn
        self.now = now
    }

    private func noteWaiting(_ text: String) {
        store.update { $0.lastAnswer = text }
    }

    func advance() async {
        // An overlapping call would run the old app's tools twice and race the journal.
        guard !advancing else { return }
        advancing = true
        defer { advancing = false }
        guard var record = store.load().record else { return }
        if record.phase == .consented {
            do {
                try TerminalTakeoverSteps.stopForGood(host)
            } catch TerminalStepError.temporary(let text), TerminalStepError.refused(let text) {
                noteWaiting(text)
                return
            } catch {
                noteWaiting(error.localizedDescription)
                return
            }
            let saved: Bool? = store.update { record in
                record.phase = .stopped
                record.lastAnswer = nil
                return true
            }
            guard saved != nil else { return }
            record.phase = .stopped
        }
        if record.needsListing || !listedThisRun {
            guard await list() else { return }
        }
        guard var current = store.load().record, current.phase >= .listed else { return }
        if !current.settingsApplied {
            guard applySettings(current) else { return }
            current.settingsApplied = true
        }
        if !current.terminalSettled {
            if !current.ownerTurnedOff { await turnTerminalOn() }
            store.update { $0.terminalSettled = true }
        }
        await settleContinuity()
        if let latest = store.load().record {
            TerminalTakeoverSteps.tidyCredential(host, continuity: latest.continuity)
        }
        store.update { $0.finishIfComplete() }
    }

    /// `false` when the old process still holds its lock.
    private func list() async -> Bool {
        switch await planner.refreshLegacyListing() {
        case .locked:
            noteWaiting(UICopy.Terminal.oldAppStillRunning)
            return false
        case .failed(let text):
            // Terminal and continuity carry on; the listing is retried.
            store.update { record in
                record.phase = max(record.phase, .listed)
                record.needsListing = true
                record.problems = [text]
            }
            return true
        case .listed(_, let held, let problems):
            listedThisRun = true
            store.update { record in
                record.phase = max(record.phase, .listed)
                record.needsListing = false
                record.heldCount = held
                record.problems = problems
                record.lastAnswer = nil
            }
            return true
        }
    }

    private func applySettings(_ record: TerminalTakeoverRecord) -> Bool {
        if let settings = record.carriedSettings {
            do {
                try FileManager.default.createDirectory(
                    at: settingsURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try settings.write(to: settingsURL, options: .atomic)
            } catch {
                noteWaiting(error.localizedDescription)
                return false
            }
        }
        store.update { $0.settingsApplied = true }
        return true
    }

    private func settleContinuity() async {
        guard let record = store.load().record, record.continuity == nil, record.phase >= .stopped else { return }
        let found = TerminalTakeoverSteps.readLegacyCredential(host)
        var legacy: TerminalContinuityPlan.Legacy?
        if let found, let deviceID = found.deviceID {
            let identity = found.journal
            legacy = TerminalContinuityPlan.Legacy(deviceID: deviceID, journal: identity)
            if record.legacyDeviceID != deviceID || record.legacyJournal != identity {
                store.update {
                    $0.legacyDeviceID = deviceID
                    $0.legacyJournal = identity
                }
            }
        } else if record.migration != nil, let deviceID = record.legacyDeviceID, let journal = record.legacyJournal {
            // A decision the journal may be holding is driven to its end, even if
            // the old credential has since gone.
            legacy = TerminalContinuityPlan.Legacy(deviceID: deviceID, journal: journal)
        }
        let pairing = await appPairing()
        switch TerminalContinuityPlan.decide(legacy: legacy, app: pairing) {
        case .wait:
            noteWaiting(pairing == nil ? UICopy.Terminal.waitingForPairing : UICopy.Terminal.waitingForMark)
        case .settle(let settled):
            store.update { $0.continuity = settled; $0.lastAnswer = nil }
        case .migrate(let replaces, let callerID):
            await sendMigration(replaces: replaces, callerID: callerID)
        }
    }

    private func sendMigration(replaces: String, callerID: String) async {
        guard now() >= migrationNextAt, let serverURL = await serverURL() else { return }
        guard let migration = store.update({
            TerminalContinuityPlan.storedOrNew(&$0, replaces: replaces, callerID: callerID)
        }) else { return }
        let answer: TerminalMigrationAnswer
        if let reply = await transport.sendMigration(serverURL: serverURL, body: migration.body) {
            answer = TerminalMigrationAnswer.classify(status: reply.status, reason: reply.reason)
        } else {
            answer = .retry("journal unreachable")
        }
        switch answer {
        case .settled(let settled):
            migrationBackoff = Self.backoffFirst
            store.update { $0.continuity = settled; $0.lastAnswer = nil }
        case .retry(let text):
            migrationNextAt = now().addingTimeInterval(migrationBackoff)
            migrationBackoff = min(migrationBackoff * 2, Self.backoffMax)
            store.update { $0.lastAnswer = text }
        }
    }
}
