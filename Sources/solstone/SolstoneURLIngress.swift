// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import SolstoneCore

public func translatePairingLink(_ raw: String) -> Result<String, PairURLError> {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed), let scheme = components.scheme else {
        return .failure(.wrongScheme(nil))
    }

    if scheme.lowercased() == "https" {
        do {
            _ = try PairURL(string: trimmed)
            return .success(trimmed)
        } catch let error as PairURLError {
            return .failure(error)
        } catch {
            return .failure(.malformedOuterURL)
        }
    }

    guard scheme.lowercased() == "solstone" else {
        return .failure(.wrongScheme(scheme))
    }

    guard components.user == nil, components.password == nil, components.port == nil else {
        return .failure(.malformedOuterURL)
    }

    guard let host = components.host, host.lowercased() == "pair" else {
        return .failure(.wrongHost(components.host))
    }

    let path = components.path
    guard path.isEmpty || path == "/" else {
        return .failure(.wrongPath(path))
    }

    guard components.percentEncodedQuery == nil else {
        return .failure(.wrongPath(path.isEmpty ? "/" : path))
    }

    guard let fragment = components.percentEncodedFragment, !fragment.isEmpty else {
        return .failure(.missingFragment)
    }

    let rebuilt = "https://go.solstone.app/p#\(fragment)"
    do {
        _ = try PairURL(string: rebuilt)
        return .success(rebuilt)
    } catch let error as PairURLError {
        return .failure(error)
    } catch {
        return .failure(.malformedOuterURL)
    }
}

enum IngressPairingDecision: Equatable, Sendable {
    case store(String)
    case leaveUntouched
}

func decideIngressPairing(
    flowState: PairingFlowState,
    heldState: SameMachineStoredPairingState,
    canonicalLink: String
) -> IngressPairingDecision {
    if flowState == .pairing || heldState != .noneHeld {
        return .leaveUntouched
    }
    return .store(canonicalLink)
}
