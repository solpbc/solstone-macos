// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum TransportEndpoint: Sendable, Equatable {
    case lan(host: String, port: Int, scope: String)
    case relay(endpoint: URL, instanceID: String, deviceToken: String)
}

public protocol ByteTransport: Sendable {
    var transportKind: String { get }

    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    func close() async
}
