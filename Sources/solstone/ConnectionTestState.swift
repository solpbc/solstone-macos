// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

public enum ConnectionTestState: Equatable, Sendable {
    case idle
    case testing
    case success
    case failure(String)
}
