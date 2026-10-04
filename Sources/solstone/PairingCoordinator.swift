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
    typealias DeletePairing = @Sendable () throws -> Void
    typealias Reactivate = @MainActor @Sendable () async -> Void
    typealias OwnerState = @MainActor @Sendable () -> TunnelLifecycleState
    typealias RelayEndpointSource = @Sendable () -> URL
    typealias DeviceLabelSource = @Sendable () -> String
    typealias ClearLastSuccessfulJournalContact = @MainActor @Sendable () -> Void
    typealias ClearJournalMarkConfirmation = @MainActor @Sendable () -> Void
    typealias RetireOwnCredential = @MainActor @Sendable (StoredPairing) async -> Void
    typealias EndSelfRetirement = @MainActor @Sendable () -> Void

    private(set) var state: PairingFlowState = .idle
    /// The one address a failed ceremony dialed, when the link named exactly one.
    private(set) var failedAddress: String?

    @ObservationIgnored
    private let pair: PairOperation
    @ObservationIgnored
    private let loadPairing: LoadPairing
    @ObservationIgnored
    private let savePairing: @Sendable (StoredPairing) throws -> Void
    @ObservationIgnored
    private let deletePairing: @Sendable () throws -> Void
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
    private var pendingSwitchLink: PairURL?
    @ObservationIgnored
    private let classifiedLog: any ClassifiedLogSinking

    var tunnelState: TunnelLifecycleState {
        ownerState()
    }

    init(
        pair: PairOperation? = nil,
        clientInfo: SPLClientInfo = SPLRuntime.clientInfo,
        keychainStore: SPLKeychainStore = SPLPairingKeychain.store(),
        credentialStore: PairingCredentialStore? = nil,
        loadPairing: LoadPairing? = nil,
        savePairing: SavePairing? = nil,
        deletePairing: DeletePairing? = nil,
        reactivate: @escaping Reactivate = {},
        ownerState: @escaping OwnerState = { .disconnected },
        relayEndpoint: @escaping RelayEndpointSource = { SPLPairingDefaults.relayEndpointURL },
        deviceLabel: @escaping DeviceLabelSource = { SPLPairingDefaults.deviceLabel },
        clearLastSuccessfulJournalContact: @escaping ClearLastSuccessfulJournalContact = {},
        clearJournalMarkConfirmation: @escaping ClearJournalMarkConfirmation = {},
        retireOwnCredential: @escaping RetireOwnCredential = { _ in },
        endSelfRetirement: @escaping EndSelfRetirement = {},
        classifiedLog: any ClassifiedLogSinking = LoggerClassifiedLogSink(logger: pairingLog)
    ) {
        let store = credentialStore ?? PairingCredentialStore(store: keychainStore)
        self.pair = pair ?? { pairURL, deviceLabel, relayEndpoint in
            try await PairClient(clientInfo: clientInfo).pair(pairURL: pairURL, deviceLabel: deviceLabel, relayEndpoint: relayEndpoint)
        }
        self.loadPairing = loadPairing ?? { try store.load() }
        if let savePairing {
            self.savePairing = savePairing
        } else {
            self.savePairing = { try store.save($0) }
        }
        if let deletePairing {
            self.deletePairing = deletePairing
        } else {
            self.deletePairing = { try store.delete() }
        }
        self.reactivate = reactivate
        self.ownerState = ownerState
        self.relayEndpoint = relayEndpoint
        self.deviceLabel = deviceLabel
        self.clearLastSuccessfulJournalContact = clearLastSuccessfulJournalContact
        self.clearJournalMarkConfirmation = clearJournalMarkConfirmation
        self.retireOwnCredential = retireOwnCredential
        self.endSelfRetirement = endSelfRetirement
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
            await retireOwnCredential(stored)
            await activate(newPairing, successState: .alreadyConnected)
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
        let stored: StoredPairing?
        do {
            stored = try loadPairing()
        } catch {
            pairingLog.error("pairing load failed during switch confirmation: \(String(describing: type(of: error)), privacy: .public)")
            stored = nil
        }
        if let stored {
            await retireOwnCredential(stored)
        }
        await activate(newPairing, successState: .switched)
    }

    func cancelSwitch() {
        pendingSwitchLink = nil
        state = .idle
    }

    func unpair() async {
        guard state != .pairing else { return }
        state = .pairing
        let stored: StoredPairing?
        do {
            stored = try loadPairing()
        } catch {
            pairingLog.error("pairing load failed before unpair: \(String(describing: type(of: error)), privacy: .public)")
            stored = nil
        }
        if let stored {
            await retireOwnCredential(stored)
        }
        do {
            let deletePairing = self.deletePairing
            try await Task.detached { try deletePairing() }.value
        } catch {
            pairingLog.error("pairing delete failed: \(String(describing: type(of: error)), privacy: .public)")
            endSelfRetirement()
            state = .failed(.localSetup)
            return
        }
        endSelfRetirement()
        pendingSwitchLink = nil
        clearJournalMarkConfirmation()
        clearLastSuccessfulJournalContact()
        await reactivate()
        state = .idle
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

    private func activate(_ pairing: StoredPairing, successState: PairingFlowState) async {
        // A new or switched pairing asks the owner to compare marks, and nothing is sent
        // until they answer, so its answer starts empty before the credential exists.
        // Pairing again with the journal this Mac already holds asks nothing: the owner
        // already answered for that journal, and the answer is kept by journal, not by link.
        if successState != .alreadyConnected {
            clearJournalMarkConfirmation()
        }
        do {
            let savePairing = self.savePairing
            try await Task.detached { try savePairing(pairing) }.value
        } catch {
            pairingLog.error("pairing save failed: \(String(describing: type(of: error)), privacy: .public)")
            endSelfRetirement()
            state = .saveFailed
            return
        }

        endSelfRetirement()
        pendingSwitchLink = nil
        clearLastSuccessfulJournalContact()
        await reactivate()
        state = successState
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
