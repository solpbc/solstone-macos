// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import Observation
import SolstoneCore

enum JournalDevicesLoadState: String, CaseIterable, Sendable {
    case loading
    case loaded
    case empty
    case notRunning = "not_running"
    case notReady = "not_ready"
}

enum PairingState {
    case idle
    case opening
    case open(link: String, qr: NSImage, deadline: Duration, nonce: String)
    case paired
    case expired(previousLink: String)
    case openFailed(detail: String)
}

extension PairingState: @unchecked Sendable {}

extension PairingState: Equatable {
    static func == (lhs: PairingState, rhs: PairingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.opening, .opening), (.paired, .paired):
            return true
        case let (.open(lhsLink, _, lhsDeadline, lhsNonce), .open(rhsLink, _, rhsDeadline, rhsNonce)):
            return lhsLink == rhsLink && lhsDeadline == rhsDeadline && lhsNonce == rhsNonce
        case let (.expired(lhsLink), .expired(rhsLink)):
            return lhsLink == rhsLink
        case let (.openFailed(lhsDetail), .openFailed(rhsDetail)):
            return lhsDetail == rhsDetail
        default:
            return false
        }
    }
}

struct JournalDeviceGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [DeviceRow]

    var count: Int { rows.count }
}

@MainActor
@Observable
final class JournalDevicesModel {
    @ObservationIgnored private let client: any JournalDevicesClientProtocol
    @ObservationIgnored private let clock: any MonotonicClock
    @ObservationIgnored private let copyToClipboard: @MainActor @Sendable (String) -> Void
    @ObservationIgnored private var activeAttemptID: UUID?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?

    var devices: [DeviceRow] = []
    var loadState: JournalDevicesLoadState = .loading
    var loadErrorDetail: String?
    var draftLabels: [String: String] = [:]
    var renamingFingerprints: Set<String> = []
    var renameErrors: [String: String] = [:]
    var revokeCandidate: DeviceRow?
    var revokeInFlightFingerprint: String?
    var revokeError: String?
    var isPairingPresented = false
    var pairingState: PairingState = .idle
    var pairingNow: Duration = .zero

    init(
        client: any JournalDevicesClientProtocol = JournalDevicesClient(),
        clock: any MonotonicClock = SystemMonotonicClock(),
        copyToClipboard: @escaping @MainActor @Sendable (String) -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        }
    ) {
        self.client = client
        self.clock = clock
        self.copyToClipboard = copyToClipboard
        self.pairingNow = clock.now()
    }

    var yourDevicesGroup: JournalDeviceGroup {
        JournalDeviceGroup(
            id: "yourDevices",
            title: DevicesCopy.yourDevicesHeader,
            rows: devices.filter { !isPeerJournal($0) }
        )
    }

    var peerJournalsGroup: JournalDeviceGroup {
        JournalDeviceGroup(
            id: "peerJournals",
            title: DevicesCopy.peerJournalsHeader,
            rows: devices.filter(isPeerJournal)
        )
    }

    var groups: [JournalDeviceGroup] {
        [yourDevicesGroup, peerJournalsGroup].filter { !$0.rows.isEmpty }
    }

    var pairingStatusToken: String {
        pairingState.axToken
    }

    func resetTransientState() {
        closePairing()
        revokeCandidate = nil
        revokeInFlightFingerprint = nil
        revokeError = nil
        renameErrors.removeAll()
        renamingFingerprints.removeAll()
    }

    func loadDevices() async {
        loadState = .loading
        do {
            let loaded = try await client.listDevices()
            applyDevices(loaded)
            loadErrorDetail = nil
            loadState = loaded.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            applyLoadError(error)
        }
    }

    func draftLabel(for row: DeviceRow) -> String {
        draftLabels[row.fingerprint] ?? displayName(for: row)
    }

    func setDraftLabel(_ label: String, for row: DeviceRow) {
        draftLabels[row.fingerprint] = label
    }

    func displayName(for row: DeviceRow) -> String {
        firstNonEmpty(row.displayLabel, row.deviceLabel, row.observerHandle)
            ?? (isPeerJournal(row) ? DevicesCopy.unnamedJournal : DevicesCopy.unnamedDevice)
    }

    func subtitle(for row: DeviceRow) -> String? {
        firstNonEmpty(row.network)
    }

    func isRenaming(_ row: DeviceRow) -> Bool {
        renamingFingerprints.contains(row.fingerprint)
    }

    func saveRename(for row: DeviceRow) async {
        let fingerprint = row.fingerprint
        let newLabel = draftLabel(for: row).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newLabel.isEmpty else {
            renameErrors[fingerprint] = DevicesCopy.renameRequired
            return
        }

        let previousDevices = devices
        let previousDraft = draftLabels[fingerprint]
        renameErrors[fingerprint] = nil
        renamingFingerprints.insert(fingerprint)
        applyOptimisticLabel(newLabel, fingerprint: fingerprint)
        draftLabels[fingerprint] = newLabel

        do {
            try await client.renameDevice(fingerprint: fingerprint, label: newLabel)
            renamingFingerprints.remove(fingerprint)
            await loadDevices()
        } catch is CancellationError {
            devices = previousDevices
            draftLabels[fingerprint] = previousDraft
            renamingFingerprints.remove(fingerprint)
        } catch {
            devices = previousDevices
            draftLabels[fingerprint] = previousDraft
            renamingFingerprints.remove(fingerprint)
            renameErrors[fingerprint] = detail(for: error) ?? DevicesCopy.renameFailed
        }
    }

    func beginRevoke(_ row: DeviceRow) {
        revokeCandidate = row
        revokeError = nil
    }

    func cancelRevoke() {
        guard revokeInFlightFingerprint == nil else { return }
        revokeCandidate = nil
        revokeError = nil
    }

    func isRevoking(_ row: DeviceRow) -> Bool {
        revokeInFlightFingerprint == row.fingerprint
    }

    func confirmRevoke() async {
        guard let row = revokeCandidate else { return }
        let fingerprint = row.fingerprint
        revokeInFlightFingerprint = fingerprint
        revokeError = nil

        do {
            _ = try await client.unpairDevice(fingerprint: fingerprint)
            devices.removeAll { $0.fingerprint == fingerprint }
            revokeCandidate = nil
            revokeInFlightFingerprint = nil
            await loadDevices()
        } catch is CancellationError {
            revokeInFlightFingerprint = nil
        } catch {
            if isPairedDeviceNotFound(error) {
                revokeCandidate = nil
                revokeInFlightFingerprint = nil
                revokeError = nil
                await loadDevices()
                return
            }
            revokeInFlightFingerprint = nil
            revokeError = detail(for: error) ?? DevicesCopy.revokeFailed
        }
    }

    func openPairing() {
        let attemptID = UUID()
        activeAttemptID = attemptID
        pairingTask?.cancel()
        pairingNow = clock.now()
        pairingState = .opening
        isPairingPresented = true

        pairingTask = Task { @MainActor [weak self] in
            await self?.drivePairing(attemptID: attemptID)
        }
    }

    func closePairing() {
        activeAttemptID = nil
        pairingTask?.cancel()
        pairingTask = nil
        isPairingPresented = false
        pairingState = .idle
        pairingNow = clock.now()
    }

    func copyOpenPairingLink() {
        guard case let .open(link, _, _, _) = pairingState else { return }
        copyToClipboard(link)
    }

    func remainingPairingSeconds() -> Int {
        guard case let .open(_, _, deadline, _) = pairingState else { return 0 }
        return Self.ceilingSeconds(deadline - pairingNow)
    }

    private func drivePairing(attemptID: UUID) async {
        do {
            let pair = try await client.startPairing()
            guard isActive(attemptID) else { return }
            let qr = try JournalQRImage.make(from: pair.pairLink)
            let deadline = clock.now() + .seconds(Int64(pair.expiresIn))
            pairingNow = clock.now()
            pairingState = .open(
                link: pair.pairLink,
                qr: qr,
                deadline: deadline,
                nonce: pair.nonce
            )

            var tick = 0
            while isActive(attemptID), !Task.isCancelled {
                pairingNow = clock.now()
                guard pairingNow < deadline else {
                    expirePairing(previousLink: pair.pairLink, attemptID: attemptID)
                    return
                }

                if tick > 0 && tick % 2 == 0 {
                    await pollPairingNonce(pair.nonce, deadline: deadline, attemptID: attemptID, previousLink: pair.pairLink)
                    guard isActive(attemptID), !Task.isCancelled else { return }
                    if case .paired = pairingState { return }
                    if case .expired = pairingState { return }
                }

                await clock.sleep(for: .seconds(1))
                tick += 1
            }
        } catch is CancellationError {
            return
        } catch {
            guard isActive(attemptID) else { return }
            pairingState = .openFailed(detail: detail(for: error) ?? DevicesCopy.pairingFailedTitle)
            pairingTask = nil
        }
    }

    private func pollPairingNonce(
        _ nonce: String,
        deadline: Duration,
        attemptID: UUID,
        previousLink: String
    ) async {
        do {
            let status = try await client.nonceStatus(nonce: nonce)
            pairingNow = clock.now()
            guard isActive(attemptID), !Task.isCancelled else { return }
            guard pairingNow < deadline else {
                expirePairing(previousLink: previousLink, attemptID: attemptID)
                return
            }
            if status.used {
                pairingState = .paired
                isPairingPresented = false
                activeAttemptID = nil
                pairingTask = nil
                await loadDevices()
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func expirePairing(previousLink: String, attemptID: UUID) {
        guard isActive(attemptID) else { return }
        pairingState = .expired(previousLink: previousLink)
        pairingTask = nil
    }

    private func isActive(_ attemptID: UUID) -> Bool {
        activeAttemptID == attemptID
    }

    private func applyDevices(_ loaded: [DeviceRow]) {
        devices = loaded
        let fingerprints = Set(loaded.map(\.fingerprint))
        draftLabels = draftLabels.filter { fingerprints.contains($0.key) }
        for row in loaded where draftLabels[row.fingerprint] == nil {
            draftLabels[row.fingerprint] = displayName(for: row)
        }
    }

    private func applyLoadError(_ error: Error) {
        devices = []
        draftLabels.removeAll()
        loadErrorDetail = detail(for: error)
        if isConnectionRefusedTransport(error) {
            loadState = .notRunning
        } else {
            loadState = .notReady
        }
    }

    private func applyOptimisticLabel(_ label: String, fingerprint: String) {
        guard let index = devices.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        devices[index].displayLabel = label
    }

    private func isPeerJournal(_ row: DeviceRow) -> Bool {
        row.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "peer"
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func detail(for error: Error) -> String? {
        guard let error = error as? JournalDevicesClientError else {
            return nil
        }
        switch error {
        case .server(let envelope):
            return firstNonEmpty(envelope.detail, envelope.error)
        case .serverStatus(let status):
            return "status \(status)"
        case .notReady, .decoding, .invalidURL, .transport:
            return nil
        }
    }

    private func isPairedDeviceNotFound(_ error: Error) -> Bool {
        guard case .server(let envelope) = error as? JournalDevicesClientError else {
            return false
        }
        return envelope.reasonCode == JournalDevicesErrorEnvelope.pairedDeviceNotFound
    }

    private func isConnectionRefusedTransport(_ error: Error) -> Bool {
        guard case .transport(let description) = error as? JournalDevicesClientError else {
            return false
        }
        return description == "\(NSURLErrorDomain):\(URLError.cannotConnectToHost.rawValue)" ||
            description == "\(NSURLErrorDomain):\(URLError.cannotFindHost.rawValue)" ||
            description == "\(NSURLErrorDomain):\(URLError.networkConnectionLost.rawValue)"
    }

    private static func ceilingSeconds(_ duration: Duration) -> Int {
        guard duration > .zero else { return 0 }
        let components = duration.components
        let extraSecond: Int64 = components.attoseconds > 0 ? 1 : 0
        let seconds = max(0, components.seconds + extraSecond)
        return seconds > Int64(Int.max) ? Int.max : Int(seconds)
    }
}
