// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalLocalAccess
import JournalMarkKit

/// The capture app's direct calls to the journal on this Mac. The answering journal is checked before
/// anything is read from it, sent to it or shown from it. Paired traffic goes through the tunnel instead.
enum OwnJournalAccess {
    static let client = JournalLocalHTTPClient(userAgent: "solstone-app", ownRoots: { await ownJournalRoots() })
    private static let base = "http://localhost"

    /// The folders this account's own journal could be in. All are this account's to read, and another
    /// account's journal carries a different instance id from anything inside them.
    static func ownJournalRoots(
        configReader: SolstoneUserConfigReading = LiveSolstoneUserConfigReader(),
        savedPath: String? = AppConfig.savedJournalPath
    ) async -> [String] {
        var roots: [String] = []
        if let raw = await configReader.readConfigToml(), let configured = parseJournalPathFromConfigToml(raw) {
            roots.append(configured)
        }
        roots.append(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("journal", isDirectory: true).standardizedFileURL.path)
        if let savedPath = savedPath?.trimmingCharacters(in: .whitespacesAndNewlines), !savedPath.isEmpty {
            roots.append(savedPath)
        }
        return roots
    }

    static func resolveIdentity(expectedInstanceID: String? = nil) async -> JournalIdentityResolution {
        let route: JournalLocalRoute
        do {
            route = try await client.verify(expectedInstanceID.map { .instance($0) } ?? .ownJournal)
        } catch {
            return identityResolution(for: error)
        }
        return await JournalIdentityFetcher(dataLoader: { try await client.send($0, via: route) })
            .resolveIdentity(baseURL: base, expectedInstanceID: expectedInstanceID)
    }

    static func startPairing(deviceLabel: String) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure> {
        await SameMachinePairStartClient(loader: { try await client.data(for: $0, anchor: .ownJournal) })
            .start(baseURL: base, deviceLabel: deviceLabel)
    }

    static func identityResolution(for error: any Error) -> JournalIdentityResolution {
        switch error {
        case JournalLocalHTTPError.refused, JournalLocalHTTPError.notOwnJournal:
            return .failed(.instanceMismatch)
        case JournalLocalHTTPError.unavailable:
            return .absent
        case JournalLocalHTTPError.timedOut:
            return .failed(.timeout)
        case JournalLocalHTTPError.invalidResponse:
            return .failed(.decodeError)
        case is CancellationError:
            return .failed(.cancelled)
        case let error as URLError:
            switch error.code {
            case .cancelled: return .failed(.cancelled)
            case .timedOut: return .failed(.timeout)
            case .cannotConnectToHost, .cannotFindHost: return .absent
            default: return .failed(.networkError)
            }
        default:
            return .failed(.networkError)
        }
    }
}
