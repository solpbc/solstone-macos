// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct Frame: Sendable, Equatable {
    public let streamID: UInt32
    public let flags: UInt8
    public let payload: Data

    public init(streamID: UInt32, flags: UInt8, payload: Data) {
        self.streamID = streamID
        self.flags = flags
        self.payload = payload
    }
}
