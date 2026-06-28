// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct ObserverHealthSnapshot: Sendable, Equatable {
    public var name: String?
    public var streamType: String
    public var version: String
    public var uptimeSeconds: Int
    public var lastSuccessfulSync: Date?
    public var pendingQueueDepth: Int
    public var recentErrorCount: Int
    public var lastErrorReason: String?

    public init(
        name: String?,
        streamType: String,
        version: String,
        uptimeSeconds: Int,
        lastSuccessfulSync: Date?,
        pendingQueueDepth: Int,
        recentErrorCount: Int,
        lastErrorReason: String?
    ) {
        self.name = name
        self.streamType = streamType
        self.version = version
        self.uptimeSeconds = uptimeSeconds
        self.lastSuccessfulSync = lastSuccessfulSync
        self.pendingQueueDepth = pendingQueueDepth
        self.recentErrorCount = recentErrorCount
        self.lastErrorReason = lastErrorReason
    }
}
