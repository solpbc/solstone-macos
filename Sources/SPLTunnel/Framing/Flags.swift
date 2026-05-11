// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum FrameFlags: UInt8, Sendable {
    case open = 0x01
    case data = 0x02
    case close = 0x04
    case reset = 0x08
    case window = 0x10
    case ping = 0x20
    case pong = 0x40

    public static let primaryMask: UInt8 =
        FrameFlags.open.rawValue |
        FrameFlags.data.rawValue |
        FrameFlags.close.rawValue |
        FrameFlags.reset.rawValue |
        FrameFlags.window.rawValue |
        FrameFlags.ping.rawValue |
        FrameFlags.pong.rawValue
    public static let reservedMask: UInt8 = 0x80
}

public enum ResetReason: UInt32, Sendable, Equatable {
    case normal = 0
    case protocolError = 1
    case flowControlError = 2
    case streamLimitExceeded = 3
    case internalError = 4
}
