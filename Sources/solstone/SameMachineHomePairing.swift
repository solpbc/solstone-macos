// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import JournalMarkKit
import SolstoneCore
import SPLTunnel

struct SameMachinePairStartResponse: Decodable, Equatable, Sendable {
    let nonce: String
    let pairLink: String
    let expiresIn: Int
    let deviceLabel: String
    let caFingerprint: String

    private enum CodingKeys: String, CodingKey {
        case nonce
        case pairLink = "pair_link"
        case expiresIn = "expires_in"
        case deviceLabel = "device_label"
        case caFingerprint = "ca_fingerprint"
    }
}

enum SameMachinePairStartFailureKind: Equatable, Sendable {
    case invalidURL
    case requestEncoding
    case transport
    case invalidResponse
    case httpStatus(Int)
    case decode
    case emptyPairLink
}

struct SameMachinePairStartFailure: Error, Equatable, Sendable {
    let kind: SameMachinePairStartFailureKind
    let detail: String

    init(kind: SameMachinePairStartFailureKind, detail: String = "") {
        self.kind = kind
        self.detail = detail
    }
}

struct SameMachinePairStartClient: Sendable {
    private struct RequestBody: Encodable, Sendable {
        let sameMachine: Bool
        let deviceLabel: String

        private enum CodingKeys: String, CodingKey {
            case sameMachine = "same_machine"
            case deviceLabel = "device_label"
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func start(
        baseURL: String,
        deviceLabel: String = SPLPairingDefaults.deviceLabel
    ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure> {
        let baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = "\(baseURL)/app/network/pair-start"
        guard let url = URL(string: endpoint) else {
            return fail(.invalidURL, "same-machine pair-start unavailable: invalid-url \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5
        request.attachLoopbackCapability()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(RequestBody(sameMachine: true, deviceLabel: deviceLabel))
        } catch {
            return fail(.requestEncoding, "same-machine pair-start encode failed: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return fail(.transport, "same-machine pair-start cancelled")
        } catch {
            return fail(.transport, "same-machine pair-start request failed: \(error)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return fail(.invalidResponse, "same-machine pair-start response was not HTTP")
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            return fail(.httpStatus(httpResponse.statusCode), "same-machine pair-start status \(httpResponse.statusCode)")
        }

        let decoded: SameMachinePairStartResponse
        do {
            decoded = try JSONDecoder().decode(SameMachinePairStartResponse.self, from: data)
        } catch {
            return fail(.decode, "same-machine pair-start decode failed: \(error)")
        }

        guard !decoded.pairLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fail(.emptyPairLink, "same-machine pair-start pair_link was empty")
        }

        return .success(decoded)
    }

    private func fail(
        _ kind: SameMachinePairStartFailureKind,
        _ detail: String
    ) -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure> {
        Logger.setup.notice("\(detail, privacy: .public)")
        return .failure(SameMachinePairStartFailure(kind: kind, detail: detail))
    }
}

enum SameMachinePairLinkRejection: Error, Equatable, Sendable {
    case lanCandidate
    case relayPairWindow
    case noCandidates
    case multipleCandidates
    case unparsable
}

func verifySameMachinePairLink(_ pairLink: String) -> Result<Void, SameMachinePairLinkRejection> {
    let pairURL: PairURL
    do {
        pairURL = try PairURL(string: pairLink)
    } catch {
        return .failure(.unparsable)
    }
    return verifySameMachinePairLink(kind: pairURL.kind, candidates: pairURL.candidates)
}

func verifySameMachinePairLink(
    kind: PairLinkKind,
    candidates: [PairCandidate]
) -> Result<Void, SameMachinePairLinkRejection> {
    guard kind == .direct else {
        return .failure(.relayPairWindow)
    }
    guard let candidate = candidates.first else {
        return .failure(.noCandidates)
    }
    guard candidates.count == 1 else {
        return .failure(.multipleCandidates)
    }
    guard LoopbackHost.isLoopbackHost(candidate.address) else {
        return .failure(.lanCandidate)
    }
    return .success(())
}

enum SameMachineStoredPairingState: Equatable, Sendable {
    case noneHeld
    case pairedHome
    case differentHomeHeld
    case unavailable
}

enum SameMachineHomePairingFailure: Equatable, Sendable {
    case pairStart(SameMachinePairStartFailureKind)
    case linkShape(SameMachinePairLinkRejection)
    case ceremony(PairingFlowState)
    case differentHomeAlreadyPaired
    case pairingUnavailable
}

enum SameMachineHomePairingResult: Equatable, Sendable {
    case notEligible
    case pairingStarted
    case failed(SameMachineHomePairingFailure)
}

@MainActor
func performSameMachineHomePairing(
    baseURL: String,
    existingPairing: SameMachineStoredPairingState,
    startPairing: @escaping @MainActor @Sendable (
        _ baseURL: String,
        _ deviceLabel: String
    ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure>,
    verifyPairLink: @escaping @Sendable (String) -> Result<Void, SameMachinePairLinkRejection> = {
        verifySameMachinePairLink($0)
    },
    submitPairingLink: @escaping @MainActor @Sendable (_ exactPairLink: String) async -> PairingFlowState
) async -> SameMachineHomePairingResult {
    switch existingPairing {
    case .noneHeld:
        break
    case .pairedHome:
        return .notEligible
    case .differentHomeHeld:
        return .failed(.differentHomeAlreadyPaired)
    case .unavailable:
        return .failed(.pairingUnavailable)
    }

    let response: SameMachinePairStartResponse
    switch await startPairing(baseURL, SPLPairingDefaults.deviceLabel) {
    case .success(let pairStartResponse):
        response = pairStartResponse
    case .failure(let failure):
        return .failed(.pairStart(failure.kind))
    }

    switch verifyPairLink(response.pairLink) {
    case .success:
        break
    case .failure(let rejection):
        return .failed(.linkShape(rejection))
    }

    let finalState = await submitPairingLink(response.pairLink)
    switch finalState {
    case .paired, .alreadyConnected:
        return .pairingStarted
    case .idle, .pairing, .switchConfirmPending, .switched, .saveFailed, .failed:
        return .failed(.ceremony(finalState))
    }
}

enum SetupVerificationFailure: Equatable, Sendable {
    case pairStart(SameMachinePairStartFailureKind)
    case linkRejection(SameMachinePairLinkRejection)
    case fingerprintMismatch
    case caPinMismatch
    case ceremony(PairingFlowState)
    case durableInstanceMismatch
    case identityFailure(JournalIdentityFailure)
    case identityAbsent
    case recordFailed
}

enum SupportingConnectionOutcome: Equatable, Sendable {
    case recorded(JournalMark)
    case alreadyRecorded
    case notEligible
    case stillSettingUp(instanceID: String?)
    case pairStartFailed(SameMachinePairStartFailureKind)
    case linkRejected(SameMachinePairLinkRejection)
    case fingerprintOrPinMismatch
    case ceremonyFailed(PairingFlowState)
    case durableInstanceMismatch
    case fetchAbsent
    case fetchFailed(JournalIdentityFailure)
    case recordFailed
}

func decodeHexPrefix16(_ hex: String) -> [UInt8]? {
    guard hex.count >= 32 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(16)
    var index = hex.startIndex
    for _ in 0..<16 {
        let nextIndex = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
        bytes.append(byte)
        index = nextIndex
    }
    return bytes
}

func caFingerprintMatches(
    expectedLowerHex: String,
    responseFingerprint: String,
    pairURL: PairURL
) -> Bool {
    let expected = expectedLowerHex.lowercased()
    guard expected.count == 64,
          expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        return false
    }
    guard responseFingerprint.lowercased() == expected else {
        return false
    }
    guard pairURL.caPin.kind == .certificateSHA256 else {
        return false
    }
    guard let prefix16 = decodeHexPrefix16(expected),
          pairURL.caPin.prefixBytes == prefix16 else {
        return false
    }
    return true
}

struct SupportingAdmission: Equatable, Sendable {
    let revision: PairingCredentialRevision
    let instanceID: String
    let caMatches: Bool

    init(revision: PairingCredentialRevision, instanceID: String, caMatches: Bool) {
        self.revision = revision
        self.instanceID = instanceID
        self.caMatches = caMatches
    }
}

func caChainContainsFingerprint(caChainPEM: String, expectedLowerHex: String) -> Bool {
    guard let certs = try? CertChain.certificates(fromPEM: caChainPEM) else {
        return false
    }
    return certs.contains { CertChain.sha256Fingerprint(of: $0) == expectedLowerHex }
}

@MainActor
func verifySupportingConnection(
    expectedInstanceID: String,
    expectedCAFingerprint: String,
    heldState: SameMachineStoredPairingState,
    isMarkAlreadyRecorded: Bool,
    operationIsCurrent: () -> Bool = { !Task.isCancelled },
    mayStartCeremony: () -> Bool = { !Task.isCancelled },
    captureAdmission: () -> SupportingAdmission?,
    confirmAdmission: (SupportingAdmission) -> Bool,
    startPairing: () async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure>,
    verifyLink: (String) -> Result<Void, SameMachinePairLinkRejection> = { verifySameMachinePairLink($0) },
    submit: (String) async -> PairingFlowState,
    durableInstanceID: () -> String?,
    resolveIdentity: () async -> JournalIdentityResolution,
    record: (JournalMark, PairingCredentialRevision) async -> Bool
) async -> SupportingConnectionOutcome {
    guard operationIsCurrent() else { return .notEligible }
    func executeFetchAndAdmission(admission: SupportingAdmission) async -> SupportingConnectionOutcome {
        let resolution = await resolveIdentity()
        guard operationIsCurrent(), confirmAdmission(admission) else {
            return .durableInstanceMismatch
        }
        switch resolution {
        case .mark(let mark, let instanceID):
            guard instanceID == expectedInstanceID, durableInstanceID() == expectedInstanceID else {
                return .durableInstanceMismatch
            }
            guard await record(mark, admission.revision) else {
                return .recordFailed
            }
            return .recorded(mark)
        case .uncommitted(let instanceID):
            return .stillSettingUp(instanceID: instanceID)
        case .absent:
            return .fetchAbsent
        case .failed(let failure):
            return .fetchFailed(failure)
        }
    }

    if durableInstanceID() == expectedInstanceID {
        guard let admission = captureAdmission() else {
            return .fetchAbsent
        }
        guard admission.instanceID == expectedInstanceID, admission.caMatches else {
            return .fingerprintOrPinMismatch
        }
        if isMarkAlreadyRecorded {
            return .alreadyRecorded
        }
        return await executeFetchAndAdmission(admission: admission)
    }

    guard heldState == .noneHeld, mayStartCeremony() else {
        return .notEligible
    }

    let startResult = await startPairing()
    guard operationIsCurrent(), mayStartCeremony() else { return .notEligible }
    let response: SameMachinePairStartResponse
    switch startResult {
    case .success(let resp):
        response = resp
    case .failure(let failure):
        return .pairStartFailed(failure.kind)
    }

    switch verifyLink(response.pairLink) {
    case .success:
        break
    case .failure(let rejection):
        return .linkRejected(rejection)
    }

    guard let pairURL = try? PairURL(string: response.pairLink) else {
        return .linkRejected(.unparsable)
    }

    guard caFingerprintMatches(
        expectedLowerHex: expectedCAFingerprint,
        responseFingerprint: response.caFingerprint,
        pairURL: pairURL
    ) else {
        return .fingerprintOrPinMismatch
    }

    let flowState = await submit(response.pairLink)
    guard operationIsCurrent() else { return .notEligible }
    switch flowState {
    case .paired, .alreadyConnected:
        break
    default:
        return .ceremonyFailed(flowState)
    }

    guard durableInstanceID() == expectedInstanceID else {
        return .durableInstanceMismatch
    }

    guard let admission = captureAdmission() else {
        return .fetchAbsent
    }
    guard admission.instanceID == expectedInstanceID, admission.caMatches else {
        return .fingerprintOrPinMismatch
    }

    return await executeFetchAndAdmission(admission: admission)
}
