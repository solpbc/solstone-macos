// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SolstoneCore
import SPLTunnel
import os

private let pairingLog = Logger(subsystem: SolstoneLogSubsystem.observerSPL, category: "pairing")

enum PairingFlowState: Equatable, Sendable {
    case idle
    case pairing
    case switchConfirmPending
    case paired
    case alreadyConnected
    case switched
    case saveFailed
    case failed(PairingFailure)
}

enum PairingFailure: Equatable, Sendable {
    case staleLink
    case homeUnreachable
    case relayUnauthorized
    case instanceMismatch
    case network
    case connectionDropped
    case invalidLink(String)
    case localSetup
}

@MainActor
@Observable
final class PairingCoordinator {
    typealias PairOperation = @Sendable (PairURL, String, URL) async throws -> StoredPairing
    typealias LoadPairing = @Sendable () throws -> StoredPairing?
    typealias SavePairing = @Sendable (StoredPairing) throws -> Void
    typealias Reactivate = @MainActor @Sendable () async -> Void
    typealias OwnerState = @MainActor @Sendable () -> TunnelLifecycleState
    typealias RelayEndpointSource = @Sendable () -> URL
    typealias DeviceLabelSource = @Sendable () -> String
    typealias ClearLastSuccessfulJournalContact = @MainActor @Sendable () -> Void
    typealias ClearJournalMarkConfirmation = @MainActor @Sendable () -> Void
    typealias RetireOwnCredential = @MainActor @Sendable (StoredPairing, String) async -> Bool
    typealias FenceOrdinaryTraffic = @MainActor @Sendable (StoredPairing) async -> Void
    typealias EndSelfRetirement = @MainActor @Sendable () -> Void

    private(set) var state: PairingFlowState = .idle
    private(set) var pendingMigrationDecision: CarriedPairingDecision?
    private(set) var replacementTargets: [CarriedPairingClientRow] = []
    private(set) var replacementOfferVisible = false
    private(set) var replacementPickerVisible = false
    private(set) var selectedReplacementCID: String?
    private(set) var migrationDecisionState: String?
    private(set) var replacementListUnavailable = false
    private(set) var replacementTargetMissing = false
    /// The one address a failed ceremony dialed, when the link named exactly one.
    private(set) var failedAddress: String?

    @ObservationIgnored
    private let pair: PairOperation
    @ObservationIgnored
    private let loadPairing: LoadPairing
    @ObservationIgnored
    private let savePairing: @Sendable (StoredPairing) throws -> Void
    @ObservationIgnored
    @ObservationIgnored
    private let reactivate: Reactivate
    @ObservationIgnored
    private let ownerState: OwnerState
    @ObservationIgnored
    private let relayEndpoint: RelayEndpointSource
    @ObservationIgnored
    private let deviceLabel: DeviceLabelSource
    @ObservationIgnored
    private let clearLastSuccessfulJournalContact: ClearLastSuccessfulJournalContact
    @ObservationIgnored
    private let clearJournalMarkConfirmation: ClearJournalMarkConfirmation
    @ObservationIgnored
    private let retireOwnCredential: RetireOwnCredential
    @ObservationIgnored
    private let endSelfRetirement: EndSelfRetirement
    @ObservationIgnored
    private let credentialStore: PairingCredentialStore?
    @ObservationIgnored
    private let fenceOrdinaryTraffic: FenceOrdinaryTraffic
    @ObservationIgnored
    private let carriedPairingControl: any CarriedPairingControlRequesting
    @ObservationIgnored
    private let localPort: @MainActor @Sendable () -> Int?
    @ObservationIgnored
    private var pendingSwitchLink: PairURL?
    @ObservationIgnored
    private let classifiedLog: any ClassifiedLogSinking
    @ObservationIgnored
    private var freshPairMarkConfirmed = false
    @ObservationIgnored
    private var inFlightFreshPairEligibility: (revision: PairingCredentialRevision, attempt: String)?

    var tunnelState: TunnelLifecycleState {
        ownerState()
    }

    init(
        pair: PairOperation? = nil,
        clientInfo: SPLClientInfo = SPLRuntime.clientInfo,
        keychainStore: any PairingStoring = SPLPairingKeychain.store(),
        credentialStore: PairingCredentialStore? = nil,
        loadPairing: LoadPairing? = nil,
        savePairing: SavePairing? = nil,
        reactivate: @escaping Reactivate = {},
        ownerState: @escaping OwnerState = { .disconnected },
        relayEndpoint: @escaping RelayEndpointSource = { SPLPairingDefaults.relayEndpointURL },
        deviceLabel: @escaping DeviceLabelSource = { SPLPairingDefaults.deviceLabel },
        clearLastSuccessfulJournalContact: @escaping ClearLastSuccessfulJournalContact = {},
        clearJournalMarkConfirmation: @escaping ClearJournalMarkConfirmation = {},
        retireOwnCredential: @escaping RetireOwnCredential = { _, _ in true },
        endSelfRetirement: @escaping EndSelfRetirement = {},
        fenceOrdinaryTraffic: @escaping FenceOrdinaryTraffic = { _ in },
        carriedPairingControl: any CarriedPairingControlRequesting = URLSessionCarriedPairingControlClient(),
        localPort: @escaping @MainActor @Sendable () -> Int? = { nil },
        classifiedLog: any ClassifiedLogSinking = LoggerClassifiedLogSink(logger: pairingLog)
    ) {
        let store = credentialStore ?? PairingCredentialStore(store: keychainStore)
        self.credentialStore = store
        self.pair = pair ?? { pairURL, deviceLabel, relayEndpoint in
            try await PairClient(clientInfo: clientInfo).pair(pairURL: pairURL, deviceLabel: deviceLabel, relayEndpoint: relayEndpoint)
        }
        self.loadPairing = loadPairing ?? { try store.load() }
        if let savePairing {
            self.savePairing = savePairing
        } else {
            self.savePairing = { try store.save($0) }
        }
        self.reactivate = reactivate
        self.ownerState = ownerState
        self.relayEndpoint = relayEndpoint
        self.deviceLabel = deviceLabel
        self.clearLastSuccessfulJournalContact = clearLastSuccessfulJournalContact
        self.clearJournalMarkConfirmation = clearJournalMarkConfirmation
        self.retireOwnCredential = retireOwnCredential
        self.endSelfRetirement = endSelfRetirement
        self.fenceOrdinaryTraffic = fenceOrdinaryTraffic
        self.carriedPairingControl = carriedPairingControl
        self.localPort = localPort
        self.classifiedLog = classifiedLog
    }

    static func linkNamesJournal(_ pairURL: PairURL, of stored: StoredPairing) -> Bool {
        let certificates: [SecCertificate]
        do {
            certificates = try CertChain.certificates(fromPEM: stored.caChainPEM)
        } catch {
            return false
        }
        for certificate in certificates {
            if CertChain.pinMatches(certificate: certificate, pin: pairURL.caPin) {
                return true
            }
        }
        return false
    }

    func submitPairingLink(_ rawLink: String) async {
        guard state != .pairing else { return }
        pendingSwitchLink = nil
        failedAddress = nil

        let pairURL: PairURL
        do {
            pairURL = try parsePairURL(rawLink)
        } catch let error as PairURLError {
            state = .failed(.invalidLink(Self.invalidLinkReason(error)))
            return
        } catch {
            state = .failed(.invalidLink("pairing link is malformed"))
            return
        }

        let stored: StoredPairing?
        do {
            stored = try loadPairing()
        } catch {
            pairingLog.error("pairing load failed before ceremony: \(String(describing: type(of: error)), privacy: .public)")
            state = .failed(.localSetup)
            return
        }

        guard let stored else {
            guard let newPairing = await runCeremony(pairURL) else { return }
            await activate(newPairing, successState: .paired)
            return
        }

        if Self.linkNamesJournal(pairURL, of: stored) {
            guard let newPairing = await runCeremony(pairURL) else { return }
            // A link pin is only a pre-ceremony hint. Custody and the mark answer
            // use the full instance + CA identity returned by the ceremony.
            guard journalMarkConfirmationIdentity(for: stored) == journalMarkConfirmationIdentity(for: newPairing) else {
                state = .failed(.instanceMismatch)
                return
            }
            guard let invalidation = await beginInvalidation(for: stored),
                  await retireInvalidatedCredential(stored, invalidation: invalidation) else { return }
            await activate(newPairing, successState: .alreadyConnected, invalidation: invalidation)
        } else {
            pendingSwitchLink = pairURL
            state = .switchConfirmPending
        }
    }

    func confirmSwitch() async {
        guard case .switchConfirmPending = state, let link = pendingSwitchLink else {
            return
        }
        guard let newPairing = await runCeremony(link) else {
            return
        }
        let stored: StoredPairing
        do {
            guard let loaded = try loadPairing() else {
                state = .failed(.localSetup)
                return
            }
            stored = loaded
        } catch {
            pairingLog.error("pairing load failed during switch confirmation: \(String(describing: type(of: error)), privacy: .public)")
            state = .failed(.localSetup)
            return
        }
        guard let invalidation = await beginInvalidation(for: stored),
              await retireInvalidatedCredential(stored, invalidation: invalidation) else { return }
        await activate(newPairing, successState: .switched, invalidation: invalidation)
    }

    func cancelSwitch() {
        pendingSwitchLink = nil
        state = .idle
    }

    func unpair() async -> Bool {
        guard state != .pairing else { return false }
        state = .pairing
        let stored: StoredPairing?
        var credentialUnreadable = false
        do {
            stored = try loadPairing()
        } catch {
            // An unreadable credential has no identity to invalidate or retire,
            // but the owner asked to unpair: remove whatever is stored.
            pairingLog.error("pairing load failed before unpair: \(String(describing: type(of: error)), privacy: .public)")
            stored = nil
            credentialUnreadable = true
        }
        if let stored {
            guard let credentialStore else {
                state = .failed(.localSetup)
                return false
            }
            guard let invalidation = await beginInvalidation(for: stored),
                  await retireInvalidatedCredential(stored, invalidation: invalidation) else { return false }
            do {
                try await Task.detached { try credentialStore.delete(after: invalidation) }.value
                var completed = invalidation
                completed.credentialCleanupPending = false
                try credentialStore.updateInvalidation(completed)
                try credentialStore.clearInvalidation(
                    operationID: completed.operationID,
                    fingerprint: completed.fingerprint,
                    revision: completed.revision,
                    expectedCurrentPairing: nil
                )
            } catch {
                pairingLog.error("pairing delete or invalidation cleanup failed: \(String(describing: type(of: error)), privacy: .public)")
                endSelfRetirement()
                state = .failed(.localSetup)
                return false
            }
        } else if let credentialStore {
            do {
                let record = credentialUnreadable ? nil : try credentialStore.carriedPairingRecord()
                if let record, let invalidation = record.invalidation {
                    guard invalidation.remoteRetirementAttempted else {
                        state = .failed(.localSetup)
                        return false
                    }
                    var completed = invalidation
                    completed.credentialCleanupPending = false
                    try credentialStore.updateInvalidation(completed)
                    try credentialStore.clearInvalidation(
                        operationID: completed.operationID,
                        fingerprint: completed.fingerprint,
                        revision: completed.revision,
                        expectedCurrentPairing: nil
                    )
                }
                try await Task.detached { try credentialStore.delete() }.value
            } catch {
                pairingLog.error("pairing delete failed without a readable credential: \(String(describing: type(of: error)), privacy: .public)")
                endSelfRetirement()
                state = .failed(.localSetup)
                return false
            }
        }
        endSelfRetirement()
        pendingSwitchLink = nil
        clearJournalMarkConfirmation()
        clearLastSuccessfulJournalContact()
        await reactivate()
        state = .idle
        return true
    }

    func recoverDurableInvalidation() async {
        guard let credentialStore,
              let record = try? credentialStore.carriedPairingRecord(),
              let invalidation = record.invalidation else { return }
        let pairing: StoredPairing?
        do { pairing = try loadPairing() }
        catch {
            state = .failed(.localSetup)
            return
        }
        guard let pairing else {
            let latestRecord: CarriedPairingRecord
            do { latestRecord = try credentialStore.carriedPairingRecord() }
            catch {
                state = .failed(.localSetup)
                return
            }
            guard latestRecord.invalidation == invalidation,
                  invalidation.remoteRetirementAttempted else {
                state = .failed(.localSetup)
                return
            }
            do {
                var completed = invalidation
                completed.credentialCleanupPending = false
                try credentialStore.updateInvalidation(completed)
                try credentialStore.clearInvalidation(operationID: completed.operationID, fingerprint: completed.fingerprint, revision: completed.revision, expectedCurrentPairing: nil)
                clearJournalMarkConfirmation()
                clearLastSuccessfulJournalContact()
                await reactivate()
                state = .idle
            } catch {
                state = .failed(.localSetup)
            }
            return
        }
        let identity = PairingCredentialRevision(from: pairing)
        guard identity.fingerprint == invalidation.fingerprint,
              identity.revision == invalidation.revision else {
            if invalidation.remoteRetirementAttempted {
                try? credentialStore.clearInvalidation(operationID: invalidation.operationID, fingerprint: invalidation.fingerprint, revision: invalidation.revision, expectedCurrentPairing: identity)
                return
            }
            state = .failed(.localSetup)
            return
        }
        await fenceOrdinaryTraffic(pairing)
        let retired: Bool
        if invalidation.remoteRetirementConfirmed {
            retired = true
        } else {
            retired = await retireOwnCredential(pairing, invalidation.operationID)
        }
        guard credentialStore.owns(identity, operationID: invalidation.operationID) else {
            state = .failed(.localSetup)
            endSelfRetirement()
            return
        }
        if !retired {
            pairingLog.notice("journal did not confirm credential retirement; local removal proceeds under the durable invalidation")
        }
        do {
            var completed = invalidation
            completed.remoteRetirementAttempted = true
            completed.remoteRetirementConfirmed = retired
            try credentialStore.updateInvalidation(completed, whilePairing: pairing)
            guard let current = try loadPairing(), PairingCredentialRevision(from: current) == identity else {
                throw PairingCredentialStoreError.staleGeneration
            }
            try await Task.detached { try credentialStore.delete(after: invalidation) }.value
            completed.credentialCleanupPending = false
            try credentialStore.updateInvalidation(completed)
            try credentialStore.clearInvalidation(operationID: completed.operationID, fingerprint: completed.fingerprint, revision: completed.revision, expectedCurrentPairing: nil)
            endSelfRetirement()
            clearJournalMarkConfirmation()
            clearLastSuccessfulJournalContact()
            pendingSwitchLink = nil
            await reactivate()
            state = .idle
        } catch {
            state = .failed(.localSetup)
            endSelfRetirement()
        }
    }

    private func beginInvalidation(for pairing: StoredPairing) async -> CarriedPairingInvalidation? {
        let invalidation: CarriedPairingInvalidation
        do {
            if let credentialStore {
                invalidation = try credentialStore.beginInvalidation(for: pairing)
            } else {
                let fingerprint = PairingCredentialRevision(from: pairing)
                invalidation = CarriedPairingInvalidation(
                    operationID: UUID().uuidString.lowercased(),
                    fingerprint: fingerprint.fingerprint,
                    journalIdentity: journalMarkConfirmationIdentity(for: pairing),
                    revision: fingerprint.revision,
                    remoteRetirementAttempted: false,
                    remoteRetirementConfirmed: false,
                    credentialCleanupPending: true
                )
            }
        } catch {
            pairingLog.error("durable pairing invalidation failed: \(String(describing: type(of: error)), privacy: .public)")
            if let credentialStore {
                let admission: CarriedPairingAdmission
                do {
                    admission = credentialStore.admission(for: try credentialStore.load())
                } catch {
                    admission = .blocked
                }
                if admission != .ready { await fenceOrdinaryTraffic(pairing) }
            }
            state = .failed(.localSetup)
            return nil
        }
        await fenceOrdinaryTraffic(pairing)
        return invalidation
    }

    private func retireInvalidatedCredential(
        _ pairing: StoredPairing,
        invalidation: CarriedPairingInvalidation
    ) async -> Bool {
        let identity = PairingCredentialRevision(from: pairing)
        guard let credentialStore,
              credentialStore.owns(identity, operationID: invalidation.operationID) else {
            state = .failed(.localSetup)
            return false
        }
        let retired = await retireOwnCredential(pairing, invalidation.operationID)
        var attempted = invalidation
        attempted.remoteRetirementAttempted = true
        attempted.remoteRetirementConfirmed = retired
        do { try credentialStore.updateInvalidation(attempted, whilePairing: pairing) }
        catch {
            endSelfRetirement()
            state = .failed(.localSetup)
            return false
        }
        // The invalidation is durable, so obsolete work stays fenced whether or
        // not the journal answered. An unreachable journal must not keep the
        // owner paired; local removal proceeds and the attempt is recorded.
        if !retired {
            pairingLog.notice("journal did not confirm credential retirement; local removal proceeds under the durable invalidation")
        }
        return true
    }

    @discardableResult
    func refreshPendingActions(markConfirmed: Bool) -> Task<Void, Never> {
        freshPairMarkConfirmed = markConfirmed
        guard let credentialStore,
              let record = try? credentialStore.carriedPairingRecord() else {
            pendingMigrationDecision = nil
            replacementOfferVisible = false
            return Task {}
        }
        pendingMigrationDecision = record.decision
        let pairing = try? credentialStore.load()
        let currentRevision = pairing.map { PairingCredentialRevision(from: $0) }
        // Visibility is derived here; "shown" is recorded only once the offer
        // sheet is actually on screen, so a launch or a confirmation that never
        // displayed it cannot consume the one-shot offer.
        replacementOfferVisible = markConfirmed
            && record.replacementOfferID != nil
            && !record.replacementOfferShown
            && pairing != nil
            && (record.freshPairObligation == nil || (currentRevision != nil && record.freshPairObligation == currentRevision))

        guard markConfirmed,
              let pairing,
              let currentRevision,
              record.freshPairObligation == currentRevision,
              record.replacementOfferID == nil,
              !record.replacementOfferShown,
              record.decision == nil,
              record.invalidation == nil else {
            return Task {}
        }
        guard let port = localPort() else { return Task {} }
        if let flight = inFlightFreshPairEligibility, flight.revision == currentRevision {
            return Task {}
        }
        let attempt = UUID().uuidString.lowercased()
        var attemptRecord = record
        attemptRecord.freshPairEligibilityAttempt = attempt
        do {
            try credentialStore.saveCarriedPairingRecord(
                attemptRecord,
                expected: record,
                whilePairing: currentRevision
            )
        } catch {
            pairingLog.error("fresh pairing eligibility save failed: \(String(describing: type(of: error)), privacy: .public)")
            return Task {}
        }
        inFlightFreshPairEligibility = (revision: currentRevision, attempt: attempt)
        return Task { [weak self] in
            await self?.finishFreshPairEligibility(port: port, revision: currentRevision, attempt: attempt)
        }
    }

    private func finishFreshPairEligibility(
        port: Int,
        revision: PairingCredentialRevision,
        attempt: String
    ) async {
        defer {
            if inFlightFreshPairEligibility?.revision == revision && inFlightFreshPairEligibility?.attempt == attempt {
                inFlightFreshPairEligibility = nil
            }
        }
        guard let credentialStore else { return }
        let rows: [CarriedPairingClientRow]
        do {
            rows = try await carriedPairingControl.clients(localPort: port)
        } catch {
            pairingLog.error("fresh pairing client list failed: \(String(describing: type(of: error)), privacy: .public)")
            guard let currentPairing = try? credentialStore.load(),
                  PairingCredentialRevision(from: currentPairing) == revision,
                  let record = try? credentialStore.carriedPairingRecord(),
                  record.freshPairObligation == revision,
                  record.freshPairEligibilityAttempt == attempt,
                  record.replacementOfferID == nil,
                  !record.replacementOfferShown,
                  record.decision == nil,
                  record.invalidation == nil else { return }
            var offerRecord = record
            offerRecord.freshPairObligation = nil
            offerRecord.freshPairEligibilityAttempt = nil
            offerRecord.replacementOfferID = UUID().uuidString.lowercased()
            offerRecord.replacementOfferShown = false
            offerRecord.decision = nil
            do {
                try credentialStore.saveCarriedPairingRecord(
                    offerRecord,
                    expected: record,
                    whilePairing: revision
                )
            } catch {
                pairingLog.error("fresh pairing follow-up state save failed: \(String(describing: type(of: error)), privacy: .public)")
                return
            }
            replacementOfferVisible = freshPairMarkConfirmed
                && offerRecord.replacementOfferID != nil
                && !offerRecord.replacementOfferShown
            return
        }

        guard let currentPairing = try? credentialStore.load(),
              PairingCredentialRevision(from: currentPairing) == revision,
              let record = try? credentialStore.carriedPairingRecord(),
              record.freshPairObligation == revision,
              record.freshPairEligibilityAttempt == attempt,
              record.replacementOfferID == nil,
              !record.replacementOfferShown,
              record.decision == nil,
              record.invalidation == nil else {
            return
        }

        let otherRows = rows.filter { $0.cid != currentPairing.fingerprint }
        var outcomeRecord = record
        outcomeRecord.freshPairObligation = nil
        outcomeRecord.freshPairEligibilityAttempt = nil
        outcomeRecord.replacementOfferShown = false
        outcomeRecord.decision = nil
        if otherRows.isEmpty {
            outcomeRecord.replacementOfferID = nil
        } else {
            outcomeRecord.replacementOfferID = UUID().uuidString.lowercased()
        }

        do {
            try credentialStore.saveCarriedPairingRecord(
                outcomeRecord,
                expected: record,
                whilePairing: revision
            )
        } catch {
            pairingLog.error("fresh pairing follow-up state save failed: \(String(describing: type(of: error)), privacy: .public)")
            return
        }

        replacementOfferVisible = freshPairMarkConfirmed
            && outcomeRecord.replacementOfferID != nil
            && !outcomeRecord.replacementOfferShown
    }

    func markReplacementOfferShown() {
        guard replacementOfferVisible,
              let credentialStore,
              var record = try? credentialStore.carriedPairingRecord(),
              record.replacementOfferID != nil,
              !record.replacementOfferShown,
              let pairing = try? credentialStore.load() else { return }
        let expectedRecord = record
        record.replacementOfferShown = true
        do {
            try credentialStore.saveCarriedPairingRecord(
                record,
                expected: expectedRecord,
                whilePairing: PairingCredentialRevision(from: pairing)
            )
        } catch {
            migrationDecisionState = "storage_unavailable"
            replacementOfferVisible = false
        }
    }

    func deferReplacementOffer() {
        guard let credentialStore,
              var record = try? credentialStore.carriedPairingRecord(),
              record.replacementOfferID != nil,
              let pairing = try? credentialStore.load() else { return }
        let expectedRecord = record
        record.replacementOfferShown = true
        do {
            try credentialStore.saveCarriedPairingRecord(
                record,
                expected: expectedRecord,
                whilePairing: PairingCredentialRevision(from: pairing)
            )
            replacementOfferVisible = false
        } catch {
            migrationDecisionState = "storage_unavailable"
        }
    }

    func openReplacementPicker() async {
        guard replacementOfferVisible,
              let credentialStore,
              let pairing = try? credentialStore.load(),
              let record = try? credentialStore.carriedPairingRecord(),
              let offerID = record.replacementOfferID,
              record.replacementOfferShown,
              record.decision == nil else { return }
        let expectedPairing = PairingCredentialRevision(from: pairing)
        replacementListUnavailable = false
        replacementTargetMissing = false
        selectedReplacementCID = nil
        guard await refreshReplacementTargets(offerID: offerID, pairing: expectedPairing) else {
            guard replacementOfferIsCurrent(offerID: offerID, pairing: expectedPairing) else { return }
            replacementListUnavailable = true
            return
        }
        guard replacementOfferIsCurrent(offerID: offerID, pairing: expectedPairing) else { return }
        replacementOfferVisible = false
        replacementPickerVisible = true
    }

    func selectReplacementTarget(cid: String?) {
        guard let cid, replacementTargets.contains(where: { $0.cid == cid }) else {
            selectedReplacementCID = nil
            return
        }
        selectedReplacementCID = cid
    }

    func dismissReplacementPicker() {
        replacementPickerVisible = false
        selectedReplacementCID = nil
        // The sheet recorded the offer as shown when it appeared. An offer
        // whose sheet never appeared stays owed for the next confirmation.
        replacementOfferVisible = false
    }

    func keepBothDevices() async {
        guard let credentialStore,
              replacementOfferVisible,
              let pairing = try? credentialStore.load(),
              let record = try? credentialStore.carriedPairingRecord(),
              let offerID = record.replacementOfferID,
              record.replacementOfferShown,
              record.decision == nil else { return }
        await persistAndSubmitFreshChoice(
            decisionID: offerID,
            choice: .newDevice,
            replacesCID: nil,
            pairing: PairingCredentialRevision(from: pairing)
        )
    }

    func confirmReplacement() async {
        guard replacementPickerVisible,
              let selectedReplacementCID,
              let credentialStore,
              let pairing = try? credentialStore.load(),
              let record = try? credentialStore.carriedPairingRecord(),
              let offerID = record.replacementOfferID,
              record.replacementOfferShown,
              record.decision == nil else { return }
        let expectedPairing = PairingCredentialRevision(from: pairing)
        guard await refreshReplacementTargets(offerID: offerID, pairing: expectedPairing) else {
            guard replacementOfferIsCurrent(offerID: offerID, pairing: expectedPairing) else { return }
            replacementListUnavailable = true
            return
        }
        guard replacementOfferIsCurrent(offerID: offerID, pairing: expectedPairing),
              replacementPickerVisible,
              self.selectedReplacementCID == selectedReplacementCID else { return }
        guard replacementTargets.contains(where: { $0.cid == selectedReplacementCID }) else {
            replacementTargetMissing = true
            return
        }
        replacementPickerVisible = false
        await persistAndSubmitFreshChoice(
            decisionID: offerID,
            choice: .replaceDevice,
            replacesCID: selectedReplacementCID,
            pairing: expectedPairing
        )
    }

    func chooseAnotherReplacementDevice() async {
        guard replacementOfferVisible || replacementPickerVisible else { return }
        guard let credentialStore,
              let pairing = try? credentialStore.load(),
              let record = try? credentialStore.carriedPairingRecord(),
              let offerID = record.replacementOfferID,
              record.replacementOfferShown,
              record.decision == nil else { return }
        let expectedPairing = PairingCredentialRevision(from: pairing)
        replacementTargetMissing = false
        replacementListUnavailable = false
        selectedReplacementCID = nil
        guard await refreshReplacementTargets(offerID: offerID, pairing: expectedPairing) else {
            guard replacementOfferIsCurrent(offerID: offerID, pairing: expectedPairing) else { return }
            replacementListUnavailable = true
            return
        }
        guard replacementOfferIsCurrent(offerID: offerID, pairing: expectedPairing) else { return }
        replacementOfferVisible = false
        replacementPickerVisible = true
    }

    func checkPendingMigrationDecision() async {
        guard let decision = pendingMigrationDecision else { return }
        await transmitDecision(decision, reconcileFirst: true)
    }

    private func refreshReplacementTargets(offerID: String, pairing expectedPairing: PairingCredentialRevision) async -> Bool {
        guard let port = localPort(),
              let credentialStore,
              let pairing = try? credentialStore.load(),
              PairingCredentialRevision(from: pairing) == expectedPairing,
              replacementOfferIsCurrent(offerID: offerID, pairing: expectedPairing) else { return false }
        do {
            let clients = try await carriedPairingControl.clients(localPort: port)
            guard replacementOfferIsCurrent(offerID: offerID, pairing: expectedPairing) else { return false }
            replacementTargets = clients.filter { $0.cid != pairing.fingerprint }
            return true
        } catch {
            return false
        }
    }

    private func replacementOfferIsCurrent(offerID: String, pairing expectedPairing: PairingCredentialRevision) -> Bool {
        guard let credentialStore,
              let pairing = try? credentialStore.load(),
              PairingCredentialRevision(from: pairing) == expectedPairing,
              let record = try? credentialStore.carriedPairingRecord() else { return false }
        return record.replacementOfferID == offerID
            && record.replacementOfferShown
            && record.decision == nil
            && record.invalidation == nil
    }

    private func persistAndSubmitFreshChoice(
        decisionID: String,
        choice: CarriedPairingChoice,
        replacesCID: String?,
        pairing expectedPairing: PairingCredentialRevision
    ) async {
        guard let credentialStore,
              let pairing = try? credentialStore.load(),
              PairingCredentialRevision(from: pairing) == expectedPairing,
              replacementOfferIsCurrent(offerID: decisionID, pairing: expectedPairing) else {
            migrationDecisionState = "storage_unavailable"
            return
        }
        let decision = CarriedPairingDecision(
            decisionID: decisionID,
            choice: choice,
            replacesCID: replacesCID,
            credentialFingerprint: pairing.fingerprint,
            credentialRevision: PairingCredentialRevision(from: pairing).revision
        )
        do {
            var record = try credentialStore.carriedPairingRecord()
            guard record.replacementOfferID == decisionID, record.decision == nil else { return }
            let expectedRecord = record
            record.decision = decision
            try credentialStore.saveCarriedPairingRecord(
                record,
                expected: expectedRecord,
                whilePairing: expectedPairing
            )
            pendingMigrationDecision = decision
            migrationDecisionState = "deciding"
        } catch {
            guard replacementOfferIsCurrent(offerID: decisionID, pairing: expectedPairing) else { return }
            migrationDecisionState = "storage_unavailable"
            return
        }
        await transmitDecision(decision, reconcileFirst: false)
    }

    private func transmitDecision(_ decision: CarriedPairingDecision, reconcileFirst: Bool) async {
        guard let credentialStore else { return }
        guard migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
        guard let pairing = try? credentialStore.load(),
              pairing.fingerprint == decision.credentialFingerprint,
              PairingCredentialRevision(from: pairing).revision == decision.credentialRevision,
              let port = localPort() else {
            migrationDecisionState = "offline"
            return
        }
        if reconcileFirst {
            do {
                let remote = try await carriedPairingControl.migrationState(localPort: port)
                guard migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
                guard remote.protocolVersion == 1,
                      remote.rekeyOperationID == nil,
                      remote.previousCID == nil,
                      remote.state == "none"
                        || (remote.state == Self.terminalState(for: decision.choice)
                            && remote.replacedCID == decision.replacesCID) else {
                    migrationDecisionState = "decision_unknown"
                    return
                }
            } catch {
                guard migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
                migrationDecisionState = "decision_unknown"
                return
            }
        }
        guard migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
        do {
            let reply = try await carriedPairingControl.decide(localPort: port, decision: decision)
            guard migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
            guard Self.replyConfirms(reply, decision: decision, pairing: pairing) else {
                migrationDecisionState = "decision_unknown"
                return
            }
            finishDecision(decision)
        } catch CarriedPairingControlError.refused {
            guard migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
            migrationDecisionState = "decision_refused"
        } catch CarriedPairingControlError.conflict {
            await replayConflictedDecision(decision, pairing: pairing, port: port)
        } catch {
            guard migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
            migrationDecisionState = "decision_unknown"
        }
    }

    /// The status API cannot name a replacement decision. Replay its
    /// already-persisted UUID and exact body so an accepted first request can
    /// return its terminal result without inventing a second operation.
    private func replayConflictedDecision(
        _ decision: CarriedPairingDecision,
        pairing: StoredPairing,
        port: Int
    ) async {
        guard let credentialStore,
              migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
        do {
            let reply = try await carriedPairingControl.decide(localPort: port, decision: decision)
            guard migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
            guard Self.replyConfirms(reply, decision: decision, pairing: pairing) else {
                migrationDecisionState = "decision_unknown"
                return
            }
            finishDecision(decision)
        } catch {
            guard migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
            migrationDecisionState = "decision_unknown"
        }
    }

    private func migrationDecisionIsCurrent(_ decision: CarriedPairingDecision, store: PairingCredentialStore) -> Bool {
        guard let pairing = try? store.load(),
              pairing.fingerprint == decision.credentialFingerprint,
              PairingCredentialRevision(from: pairing).revision == decision.credentialRevision,
              let record = try? store.carriedPairingRecord() else { return false }
        guard record.invalidation == nil, record.decision == decision else { return false }
        return record.replacementOfferID == decision.decisionID && record.replacementOfferShown
    }

    private func finishDecision(_ decision: CarriedPairingDecision) {
        guard let credentialStore,
              migrationDecisionIsCurrent(decision, store: credentialStore) else { return }
        guard let pairing = try? credentialStore.load(),
              pairing.fingerprint == decision.credentialFingerprint,
              PairingCredentialRevision(from: pairing).revision == decision.credentialRevision else {
            return
        }
        do {
            var record = try credentialStore.carriedPairingRecord()
            guard record.invalidation == nil, record.decision == decision else { return }
            let expectedRecord = record
            record.decision = nil
            record.replacementOfferID = nil
            record.replacementOfferShown = true
            try credentialStore.saveCarriedPairingRecord(
                record,
                expected: expectedRecord,
                whilePairing: PairingCredentialRevision(from: pairing)
            )
            pendingMigrationDecision = nil
            migrationDecisionState = nil
            replacementOfferVisible = false
            replacementPickerVisible = false
        } catch {
            migrationDecisionState = "storage_unavailable"
        }
    }

    private static func terminalState(for choice: CarriedPairingChoice) -> String {
        switch choice {
        case .newDevice: "new_device"
        case .replaceDevice: "replaced_device"
        }
    }

    /// Only the exact terminal answer for this decision confirms it; anything
    /// else stays unknown.
    private static func replyConfirms(
        _ reply: CarriedPairingDecisionReply,
        decision: CarriedPairingDecision,
        pairing: StoredPairing
    ) -> Bool {
        reply.protocolVersion == 1
            && reply.operationID == decision.decisionID
            && reply.state == terminalState(for: decision.choice)
            && reply.cid == pairing.fingerprint
            && reply.previousCID == nil
            && reply.replacedCID == decision.replacesCID
    }

    private func parsePairURL(_ rawLink: String) throws -> PairURL {
        let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        return try PairURL(string: trimmed)
    }

    private func runCeremony(_ pairURL: PairURL) async -> StoredPairing? {
        state = .pairing
        do {
            return try await pair(pairURL, deviceLabel(), relayEndpoint())
        } catch {
            classifiedLog.emit(
                ClassifiedLogEmission(
                    level: .notice,
                    classification: "pairing-refused",
                    publicFields: ["errorType": String(describing: type(of: error))]
                )
            )
            let failure = Self.failure(for: error)
            failedAddress = failure == .homeUnreachable ? Self.singleCandidateAddress(pairURL) : nil
            state = .failed(failure)
            return nil
        }
    }

    private func activate(
        _ pairing: StoredPairing,
        successState: PairingFlowState,
        invalidation: CarriedPairingInvalidation? = nil
    ) async {
        do {
            if let invalidation, let credentialStore {
                try await Task.detached {
                    try credentialStore.save(pairing, after: invalidation)
                }.value
            } else {
                let savePairing = self.savePairing
                try await Task.detached { try savePairing(pairing) }.value
            }
        } catch {
            pairingLog.error("pairing save failed: \(String(describing: type(of: error)), privacy: .public)")
            endSelfRetirement()
            state = .saveFailed
            return
        }

        // A new journal asks the owner to compare marks after its credential is
        // durable. Same-journal certificate rotation keeps that confirmation.
        if successState != .alreadyConnected {
            clearJournalMarkConfirmation()
        }

        do {
            if successState == .alreadyConnected {
                if let invalidation, let credentialStore {
                    try credentialStore.clearInvalidation(
                        operationID: invalidation.operationID,
                        fingerprint: invalidation.fingerprint,
                        revision: invalidation.revision,
                        expectedCurrentPairing: PairingCredentialRevision(from: pairing)
                    )
                }
            } else if (successState == .paired || successState == .switched), let credentialStore {
                let expectedRecord = try credentialStore.carriedPairingRecord()
                var record = expectedRecord
                record.freshPairObligation = PairingCredentialRevision(from: pairing)
                record.freshPairEligibilityAttempt = nil
                record.replacementOfferID = nil
                record.replacementOfferShown = false
                record.decision = nil
                record.invalidation = nil
                try credentialStore.saveCarriedPairingRecord(
                    record,
                    expected: expectedRecord,
                    whilePairing: PairingCredentialRevision(from: pairing)
                )
            }
        } catch {
            pairingLog.error("pairing follow-up state save failed: \(String(describing: type(of: error)), privacy: .public)")
            endSelfRetirement()
            state = .saveFailed
            return
        }

        endSelfRetirement()
        pendingSwitchLink = nil
        clearLastSuccessfulJournalContact()
        await reactivate()
        state = successState
        _ = refreshPendingActions(markConfirmed: false)
    }

    static func failure(for error: any Error) -> PairingFailure {
        if let pairError = error as? PairError {
            return failure(for: pairError)
        }
        if let dialError = error as? DialError {
            return failure(for: dialError)
        }
        if let pairURLError = error as? PairURLError {
            return .invalidLink(invalidLinkReason(pairURLError))
        }
        return .network
    }

    static func failure(for error: PairError) -> PairingFailure {
        switch error {
        case .csrBuildFailed:
            return .localSetup
        case .lanRequestFailed(let underlying):
            if let dialError = underlying as? DialError {
                return failure(for: dialError)
            }
            return .homeUnreachable
        case .lanCAFingerprintMismatch:
            return .instanceMismatch
        case .lanResponseInvalid(let status):
            if let status, (500...599).contains(status) {
                return .homeUnreachable
            }
            return .network
        case .nonceExpired:
            return .staleLink
        case .pairingWindowClosed:
            return .staleLink
        case .lanClosedBeforeResponse:
            return .connectionDropped
        case .directAddressNotLocal:
            return .invalidLink("this pairing link contains an address that can't be used for direct pairing. get a fresh link from your journal and try again.")
        case .lanCandidatesExhausted(let sawCAFingerprintMismatch):
            return sawCAFingerprintMismatch ? .instanceMismatch : .homeUnreachable
        case .relayRequestFailed(let underlying):
            if let dialError = underlying as? DialError {
                return failure(for: dialError)
            }
            return .network
        case .relayResponseInvalid(let status):
            if status == 401 || status == 403 {
                return .relayUnauthorized
            }
            return .network
        case .relayInstanceMismatch:
            return .instanceMismatch
        case .relayAccessInvalid:
            return .network
        case .attestationRejected(let status):
            if status == 401 || status == 403 || status == 409 {
                return .staleLink
            }
            return .relayUnauthorized
        }
    }

    static func failure(for error: DialError) -> PairingFailure {
        switch error {
        case .invalidPort:
            return .localSetup
        case .invalidRelayURL:
            return .localSetup
        case .connectTimeout:
            return .homeUnreachable
        case .connectionFailed:
            return .homeUnreachable
        case .sendFailed:
            return .homeUnreachable
        case .receiveFailed:
            return .homeUnreachable
        case .unexpectedTextFrame:
            return .homeUnreachable
        case .relayNotEntitled:
            return .relayUnauthorized
        case .relayUnauthorized:
            return .relayUnauthorized
        case .relayCloseUnauthorized:
            return .staleLink
        case .pairingWindowClosed:
            return .staleLink
        case .relayInstanceUnknown:
            return .instanceMismatch
        case .wsHandshakeFailed(let httpStatus):
            if httpStatus == 401 || httpStatus == 403 {
                return .relayUnauthorized
            }
            if httpStatus == 404 {
                return .instanceMismatch
            }
            if let httpStatus, (500...599).contains(httpStatus) {
                return .homeUnreachable
            }
            return .network
        }
    }

    static func singleCandidateAddress(_ pairURL: PairURL) -> String? {
        let addresses = JournalAddressText.distinct(pairURL.candidates.map {
            JournalAddressText.format(host: $0.address, port: Int($0.port))
        })
        return addresses.count == 1 ? addresses[0] : nil
    }

    static func invalidLinkReason(_ error: PairURLError) -> String {
        switch error {
        case .wrongScheme(nil):
            return "pairing link must use https"
        case .wrongScheme(let scheme?):
            return "pairing link must use https, got \(scheme)"
        case .wrongHost(nil):
            return "pairing link must use go.solstone.app"
        case .wrongHost(let host?):
            return "pairing link must use go.solstone.app, got \(host)"
        case .wrongPath(let path):
            return "pairing link path must be /p, got \(path)"
        case .missingFragment:
            return "pairing link is missing its code"
        case .invalidBase32(.outOfAlphabet(let character)):
            return "pairing link contains an invalid character: \(character)"
        case .invalidBase32(.nonCanonicalPadBits):
            return "pairing link contains invalid encoded data"
        case .invalidVersion(let version):
            return "pairing link version is unsupported: \(hexByte(version))"
        case .unsupportedAddrType(let addressType):
            return "pairing link address type is unsupported: \(hexByte(addressType))"
        case .unsupportedCAFingerprintTag(let tag):
            return "pairing link fingerprint type is unsupported: \(hexByte(tag))"
        case .invalidRelayOrigin:
            return "pairing link relay origin is invalid"
        case .invalidLength(let count):
            return "pairing link data length is invalid: \(count) bytes"
        case .malformedOuterURL:
            return "pairing link is malformed"
        }
    }

    private static func hexByte(_ value: UInt8) -> String {
        String(format: "0x%02x", value)
    }
}

extension PairingFailure {
    var message: String {
        message(address: nil)
    }

    func message(address: String?) -> String {
        switch self {
        case .staleLink:
            return "this pairing window closed or expired. get a fresh link from your journal's network app and try again."
        case .homeUnreachable:
            if let address {
                return "couldn't reach your journal at \(address). make sure it's running, then try again."
            }
            return "couldn't reach your journal. make sure it's running, then try again."
        case .relayUnauthorized:
            return "your journal didn't accept this pairing link. get a fresh link from its network app and try again."
        case .instanceMismatch:
            return "this link is for a different journal. get a fresh link from the journal you want."
        case .network:
            return "pairing couldn't reach your journal. check your connection and try again."
        case .connectionDropped:
            return "lost the connection to your journal before it answered. try again."
        case .invalidLink(let reason):
            return reason
        case .localSetup:
            return "pairing couldn't start on this mac. try again."
        }
    }
}
