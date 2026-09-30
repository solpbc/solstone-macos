// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation

public actor BrowserHostUpdateGate {
    public static let interval: TimeInterval = 300

    private let clock: @Sendable () -> Date
    private let checkForUpdates: @MainActor @Sendable () -> Void
    public private(set) var lastRequestedAt: Date?
    private var requestRevision = 0

    public init(
        clock: @escaping @Sendable () -> Date = Date.init,
        checkForUpdates: @escaping @MainActor @Sendable () -> Void
    ) {
        self.clock = clock
        self.checkForUpdates = checkForUpdates
    }

    @discardableResult
    public func requestForAppBehindHello(isCurrent: @escaping @Sendable () -> Bool = { true }) async -> Bool {
        guard isCurrent() else { return false }
        let now = clock()
        if let lastRequestedAt, now.timeIntervalSince(lastRequestedAt) < Self.interval {
            return false
        }
        let previous = lastRequestedAt
        requestRevision &+= 1
        let revision = requestRevision
        lastRequestedAt = now
        let invoked = await MainActor.run {
            guard isCurrent() else { return false }
            checkForUpdates()
            return true
        }
        if !invoked, requestRevision == revision { lastRequestedAt = previous }
        return invoked
    }
}

enum BrowserHostUpdateEligibility {
    static func shouldRequest(
        decoded: BrowserDecodeResult,
        firstMessage: Bool,
        fresh: Bool,
        allowlisted: Bool,
        modeMatches: Bool,
        obsolete: Bool
    ) -> Bool {
        guard firstMessage, fresh, allowlisted, modeMatches, !obsolete,
              case .unsupported(_, let behind) = decoded else { return false }
        return behind == "app"
    }
}

#endif
