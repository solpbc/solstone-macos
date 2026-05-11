// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum FramingLimits {
    public static let maxPayload: Int = 0x00ff_ffff
}

public enum FramingError: Error, Equatable {
    case payloadTooLarge
    case reservedBitsSet
    case noPrimaryFlag
    case invalidFlagCombination
    case lengthMismatch
    case bufferUnderflow
    case unknownResetReason(UInt32)
}

public func encodeFrame(_ frame: Frame) throws -> Data {
    try validateFlags(frame.flags)
    let length = frame.payload.count
    guard length <= FramingLimits.maxPayload else {
        throw FramingError.payloadTooLarge
    }

    var data = Data()
    data.reserveCapacity(8 + length)
    data.append(UInt8((frame.streamID >> 24) & 0xff))
    data.append(UInt8((frame.streamID >> 16) & 0xff))
    data.append(UInt8((frame.streamID >> 8) & 0xff))
    data.append(UInt8(frame.streamID & 0xff))
    data.append(frame.flags)
    data.append(UInt8((length >> 16) & 0xff))
    data.append(UInt8((length >> 8) & 0xff))
    data.append(UInt8(length & 0xff))
    data.append(frame.payload)
    return data
}

public func validateFlags(_ flags: UInt8) throws {
    guard flags & FrameFlags.reservedMask == 0 else {
        throw FramingError.reservedBitsSet
    }
    guard flags & FrameFlags.primaryMask != 0 else {
        throw FramingError.noPrimaryFlag
    }

    let hasOpen = flags & FrameFlags.open.rawValue != 0
    let hasData = flags & FrameFlags.data.rawValue != 0
    let hasClose = flags & FrameFlags.close.rawValue != 0
    let hasReset = flags & FrameFlags.reset.rawValue != 0

    if hasOpen && hasReset {
        throw FramingError.invalidFlagCombination
    }
    if hasOpen && hasData && hasClose {
        throw FramingError.invalidFlagCombination
    }
}

public struct FrameDecoder {
    private var buffer = Data()
    private var cursor = 0

    public init() {}

    public mutating func feed(_ bytes: Data) {
        if bytes.count == 1, let byte = bytes.first {
            buffer.append(byte)
        } else {
            buffer.append(bytes)
        }
    }

    public mutating func next() throws -> Frame? {
        guard buffer.count - cursor >= 8 else {
            return nil
        }

        let streamID =
            (UInt32(buffer[cursor]) << 24) |
            (UInt32(buffer[cursor + 1]) << 16) |
            (UInt32(buffer[cursor + 2]) << 8) |
            UInt32(buffer[cursor + 3])
        let flags = buffer[cursor + 4]
        try validateFlags(flags)
        let length =
            (Int(buffer[cursor + 5]) << 16) |
            (Int(buffer[cursor + 6]) << 8) |
            Int(buffer[cursor + 7])

        guard buffer.count - cursor >= 8 + length else {
            return nil
        }

        let payloadStart = cursor + 8
        let payloadEnd = payloadStart + length
        let payload = Data(buffer[payloadStart..<payloadEnd])
        cursor = payloadEnd

        if cursor > (64 << 10) || cursor > buffer.count / 2 {
            buffer.removeSubrange(0..<cursor)
            cursor = 0
        }

        return Frame(streamID: streamID, flags: flags, payload: payload)
    }
}

public func buildOpen(streamID: UInt32) -> Frame {
    Frame(streamID: streamID, flags: FrameFlags.open.rawValue, payload: Data())
}

public func buildData(streamID: UInt32, payload: Data) -> Frame {
    Frame(streamID: streamID, flags: FrameFlags.data.rawValue, payload: payload)
}

public func buildClose(streamID: UInt32) -> Frame {
    Frame(streamID: streamID, flags: FrameFlags.close.rawValue, payload: Data())
}

public func buildReset(streamID: UInt32, reason: ResetReason) -> Frame {
    Frame(streamID: streamID, flags: FrameFlags.reset.rawValue, payload: encodeUInt32(reason.rawValue))
}

public func buildWindow(streamID: UInt32, credit: UInt32) -> Frame {
    Frame(streamID: streamID, flags: FrameFlags.window.rawValue, payload: encodeUInt32(credit))
}

public func parseResetReason(from payload: Data) throws -> ResetReason {
    let raw = try parseUInt32(from: payload)
    guard let reason = ResetReason(rawValue: raw) else {
        throw FramingError.unknownResetReason(raw)
    }
    return reason
}

public func parseWindowCredit(from payload: Data) throws -> UInt32 {
    try parseUInt32(from: payload)
}

private func encodeUInt32(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ])
}

private func parseUInt32(from payload: Data) throws -> UInt32 {
    guard payload.count == 4 else {
        throw FramingError.lengthMismatch
    }
    return (UInt32(payload[0]) << 24) |
        (UInt32(payload[1]) << 16) |
        (UInt32(payload[2]) << 8) |
        UInt32(payload[3])
}
