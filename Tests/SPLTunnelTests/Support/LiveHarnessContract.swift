// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

enum LiveHarnessDefaults {
    static let stagingRelayEndpoint = "https://spl-relay-staging.jer-3f2.workers.dev"
}

struct LiveEnvConfig {
    let pairURL: PairURL
    let relayEndpoint: URL
    let forceRelay: Bool
}

enum LiveEnvError: Error, CustomStringConvertible {
    case missingPairURL
    case malformedRelayEndpoint(String)
    case pairURLRejected(PairURLError)

    var description: String {
        switch self {
        case .missingPairURL:
            "SPL_PAIR_URL is missing or empty"
        case .malformedRelayEndpoint(let value):
            "SPL_RELAY_ENDPOINT is not a valid URL: \(value)"
        case .pairURLRejected(let error):
            "SPL_PAIR_URL was rejected: \(error)"
        }
    }
}

func parseLiveEnv(_ env: [String: String]) throws -> LiveEnvConfig {
    let rawPairURL = env["SPL_PAIR_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !rawPairURL.isEmpty else {
        throw LiveEnvError.missingPairURL
    }

    let pairURL: PairURL
    do {
        pairURL = try PairURL(string: rawPairURL)
    } catch let error as PairURLError {
        throw LiveEnvError.pairURLRejected(error)
    }

    let relayEndpointString = env["SPL_RELAY_ENDPOINT"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let relayEndpointValue = relayEndpointString?.isEmpty == false
        ? relayEndpointString!
        : LiveHarnessDefaults.stagingRelayEndpoint
    guard let relayEndpoint = URL(string: relayEndpointValue) else {
        throw LiveEnvError.malformedRelayEndpoint(relayEndpointValue)
    }

    return LiveEnvConfig(
        pairURL: pairURL,
        relayEndpoint: relayEndpoint,
        forceRelay: env["SPL_FORCE_RELAY"] == "1"
    )
}

enum RelayPreconditionError: Error, CustomStringConvertible {
    case relayEnrollmentUnavailable
    case noRelayCandidates

    var description: String {
        switch self {
        case .relayEnrollmentUnavailable:
            "relay enrollment is unavailable"
        case .noRelayCandidates:
            "relay enrollment exists but no relay transport candidates were built"
        }
    }
}

func relayOnlyCandidates(for pairing: StoredPairing) throws -> [TransportEndpoint] {
    if case .unavailable = pairing.relayEnrollment {
        throw RelayPreconditionError.relayEnrollmentUnavailable
    }

    let relayEndpoints = TransportEndpoint.candidates(for: pairing).filter { endpoint in
        if case .relay = endpoint {
            return true
        }
        return false
    }
    guard !relayEndpoints.isEmpty else {
        throw RelayPreconditionError.noRelayCandidates
    }
    return relayEndpoints
}
