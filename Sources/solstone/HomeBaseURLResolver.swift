// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

public enum ResolvedHomeBase: Sendable, Equatable {
    case url(String)
    case held
}

public struct HomeBaseURLResolver: Sendable {
    public let resolve: @Sendable () async -> ResolvedHomeBase

    public init(resolve: @escaping @Sendable () async -> ResolvedHomeBase) {
        self.resolve = resolve
    }
}
