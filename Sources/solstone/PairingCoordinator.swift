// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SolstoneCore
import SPLTunnel
import os

private let pairingLog = Logger(subsystem: "app.solstone.observer.spl", category: "pairing")

enum PairingFlowState: Equatable, Sendable {
    case idle
    case pairing
    case switchConfirmPending(newInstanceID: String)
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

    private static let nonRelayPairingLinkReason = "pairing link is not a relay link"

    private(set) var state: PairingFlowState = .idle

    @ObservationIgnored
    private let pair: PairOperation
    @ObservationIgnored
    private let loadPairing: LoadPairing
    @ObservationIgnored
    private let savePairing: SavePairing
    @ObservationIgnored
    private let deletePairing: DeletePairing
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
    private var pendingSwitchPairing: StoredPairing?

    var tunnelState: TunnelLifecycleState {
        ownerState()
    }

    init(
        pair: PairOperation? = nil,
        clientInfo: SPLClientInfo = SPLRuntime.clientInfo,
        keychainStore: SPLKeychainStore = SPLPairingKeychain.store(),
        loadPairing: LoadPairing? = nil,
        savePairing: SavePairing? = nil,
        deletePairing: DeletePairing? = nil,
        reactivate: @escaping Reactivate = {},
        ownerState: @escaping OwnerState = { .disconnected },
        relayEndpoint: @escaping RelayEndpointSource = { SPLPairingDefaults.relayEndpointURL },
        deviceLabel: @escaping DeviceLabelSource = { SPLPairingDefaults.deviceLabel },
        clearLastSuccessfulJournalContact: @escaping ClearLastSuccessfulJournalContact = {}
    ) {
        self.pair = pair ?? { pairURL, deviceLabel, relayEndpoint in
            try await PairClient(clientInfo: clientInfo).pair(pairURL: pairURL, deviceLabel: deviceLabel, relayEndpoint: relayEndpoint)
        }
        self.loadPairing = loadPairing ?? { try keychainStore.load() }
        self.savePairing = savePairing ?? { try keychainStore.save($0) }
        self.deletePairing = deletePairing ?? { try keychainStore.delete() }
        self.reactivate = reactivate
        self.ownerState = ownerState
        self.relayEndpoint = relayEndpoint
        self.deviceLabel = deviceLabel
        self.clearLastSuccessfulJournalContact = clearLastSuccessfulJournalContact
    }

    func submitPairingLink(_ rawLink: String) async {
        pendingSwitchPairing = nil

        let pairURL: PairURL
        do {
            pairURL = try parseRelayPairURL(rawLink)
        } catch let error as PairURLError {
            state = .failed(.invalidLink(Self.invalidLinkReason(error)))
            return
        } catch let failure as LocalPairingFailure {
            state = .failed(failure.failure)
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
            await runCeremony(pairURL, stored: nil)
            return
        }

        await runCeremony(pairURL, stored: stored)
    }

    func confirmSwitch() async {
        guard let pairing = pendingSwitchPairing else {
            return
        }
        await activate(pairing, successState: .switched)
    }

    func cancelSwitch() {
        pendingSwitchPairing = nil
        state = .idle
    }

    func unpair() async {
        do {
            try deletePairing()
        } catch {
            pairingLog.error("pairing delete failed: \(String(describing: type(of: error)), privacy: .public)")
            state = .failed(.localSetup)
            return
        }
        pendingSwitchPairing = nil
        clearLastSuccessfulJournalContact()
        await reactivate()
        state = .idle
    }

    private func parseRelayPairURL(_ rawLink: String) throws -> PairURL {
        let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairURL = try PairURL(string: trimmed)
        guard pairURL.kind == .relay else {
            throw LocalPairingFailure(.invalidLink(Self.nonRelayPairingLinkReason))
        }
        return pairURL
    }

    private func runCeremony(_ pairURL: PairURL, stored: StoredPairing?) async {
        state = .pairing
        let newPairing: StoredPairing
        do {
            newPairing = try await pair(pairURL, deviceLabel(), relayEndpoint())
        } catch {
            pairingLog.info("pairing ceremony failed: \(String(describing: type(of: error)), privacy: .public)")
            state = .failed(Self.failure(for: error))
            return
        }

        guard let stored else {
            await activate(newPairing, successState: .paired)
            return
        }

        if stored.instanceID.caseInsensitiveCompare(newPairing.instanceID) == .orderedSame {
            await activate(newPairing, successState: .alreadyConnected)
            return
        }

        pendingSwitchPairing = newPairing
        state = .switchConfirmPending(newInstanceID: newPairing.instanceID)
    }

    private func activate(_ pairing: StoredPairing, successState: PairingFlowState) async {
        do {
            try savePairing(pairing)
        } catch {
            pairingLog.error("pairing save failed: \(String(describing: type(of: error)), privacy: .public)")
            state = .saveFailed
            return
        }

        pendingSwitchPairing = nil
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
        case .directAddressNotLocal:
            return .invalidLink(nonRelayPairingLinkReason)
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

private struct LocalPairingFailure: Error {
    let failure: PairingFailure

    init(_ failure: PairingFailure) {
        self.failure = failure
    }
}

extension PairingFailure {
    var message: String {
        switch self {
        case .staleLink:
            return "this pairing window closed or expired. get a fresh link from your journal's network app and try again."
        case .homeUnreachable:
            return "couldn't reach your journal. on the same wi-fi as your journal, or over your own vpn, it connects directly; from elsewhere it needs the paid plan."
        case .relayUnauthorized:
            return "your journal didn't accept this pairing link. get a fresh link from its network app and try again."
        case .instanceMismatch:
            return "this link is for a different journal. get a fresh link from the journal you want."
        case .network:
            return "pairing couldn't reach your journal. check your connection and try again."
        case .invalidLink(let reason):
            return reason
        case .localSetup:
            return "pairing couldn't start on this Mac. try again."
        }
    }
}
