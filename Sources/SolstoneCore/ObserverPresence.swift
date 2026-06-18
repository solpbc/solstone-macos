// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct ObserverPresenceTransition: Equatable, Sendable {
    public let newLastKnownPID: Int32?
    public let terminatedPID: Int32?

    public init(newLastKnownPID: Int32?, terminatedPID: Int32?) {
        self.newLastKnownPID = newLastKnownPID
        self.terminatedPID = terminatedPID
    }
}

public func observerPresenceTransition(
    lastKnownPID: Int32?,
    currentObserverPID: Int32?
) -> ObserverPresenceTransition {
    if let lastKnownPID, currentObserverPID == nil {
        return ObserverPresenceTransition(newLastKnownPID: nil, terminatedPID: lastKnownPID)
    }

    return ObserverPresenceTransition(newLastKnownPID: currentObserverPID, terminatedPID: nil)
}
