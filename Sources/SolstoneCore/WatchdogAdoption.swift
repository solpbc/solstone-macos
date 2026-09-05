// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct WatchdogRunningCandidate: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public let bundleURL: URL?
    public let shortVersion: String?
    public let buildVersion: String?

    public init(
        bundleIdentifier: String?,
        processIdentifier: Int32,
        bundleURL: URL?,
        shortVersion: String? = nil,
        buildVersion: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.bundleURL = bundleURL
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
    }
}

public enum WatchdogAdoptionDecision: Equatable, Sendable {
    case adopt(pid: Int32)
    case conflictingCopy(bundleURL: URL?, shortVersion: String?, buildVersion: String?)
    case noCandidate
}

public func watchdogAdoptionDecision(
    product: WatchdogProduct,
    ownerBundleURL: URL,
    candidates: [WatchdogRunningCandidate]
) -> WatchdogAdoptionDecision {
    let matchingCandidates = candidates.filter { $0.bundleIdentifier == product.targetBundleID }
    guard !matchingCandidates.isEmpty else { return .noCandidate }

    let normalizedOwnerURL = WatchdogAppLocationEligibility.normalized(ownerBundleURL)
    if let ownerCandidate = matchingCandidates.first(where: { candidate in
        guard let bundleURL = candidate.bundleURL else { return false }
        // Path equality is not signer identity; code-signing verification is deferred to future work.
        return WatchdogAppLocationEligibility.normalized(bundleURL) == normalizedOwnerURL
    }) {
        return .adopt(pid: ownerCandidate.processIdentifier)
    }

    let conflictingCandidate = matchingCandidates[0]
    return .conflictingCopy(
        bundleURL: conflictingCandidate.bundleURL,
        shortVersion: conflictingCandidate.shortVersion,
        buildVersion: conflictingCandidate.buildVersion
    )
}
