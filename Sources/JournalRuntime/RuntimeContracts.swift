// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct MaterializedRuntime: Sendable {
    public let key: String
    public let layout: SolstoneRuntimeLayout
    public let environment: [String: String]

    public init(
        key: String,
        layout: SolstoneRuntimeLayout,
        environment: [String: String]? = nil
    ) {
        self.key = key
        self.layout = layout
        self.environment = environment ?? ProcessInfo.processInfo.environment
    }
}

public protocol RuntimeMaterializing: Sendable {
    func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime
}
