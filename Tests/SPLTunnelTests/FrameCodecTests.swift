// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SPLTunnel

private enum Fixtures {
    static let open1: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00
    ]
    static let openMax: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0x01, 0x00, 0x00, 0x00
    ]
    static let dataA: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x02, 0x00, 0x00, 0x01, 0x41
    ]
    static let dataEmpty: [UInt8] = [
        0x00, 0x00, 0x00, 0x03, 0x02, 0x00, 0x00, 0x00
    ]
    static let data64KiB: Data = {
        var data = Data([0x00, 0x00, 0x00, 0x05, 0x02, 0x01, 0x00, 0x00])
        data.append(Data(repeating: 0, count: 64 * 1024))
        return data
    }()
    static let close1: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x00
    ]
    static let resetProtocolError: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x08, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x01
    ]
    static let resetFlowControlError: [UInt8] = [
        0x00, 0x00, 0x00, 0x07, 0x08, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x02
    ]
    static let window64KiB: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x10, 0x00, 0x00, 0x04,
        0x00, 0x01, 0x00, 0x00
    ]
    static let ping: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ]
    static let pong: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ]
    static let dataFourBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x09, 0x02, 0x00, 0x00, 0x04,
        0x01, 0x02, 0x03, 0x04
    ]
}

@Suite("FrameCodecWireCompat")
struct FrameCodecWireCompatTests {
    @Test func openStreamOne() throws {
        try expectFixture(buildOpen(streamID: 1), bytes: Data(Fixtures.open1))
    }

    @Test func openMaxStreamID() throws {
        try expectFixture(buildOpen(streamID: 0xffff_ffff), bytes: Data(Fixtures.openMax))
    }

    @Test func dataOneByte() throws {
        try expectFixture(buildData(streamID: 1, payload: Data([0x41])), bytes: Data(Fixtures.dataA))
    }

    @Test func dataEmptyPayload() throws {
        try expectFixture(buildData(streamID: 3, payload: Data()), bytes: Data(Fixtures.dataEmpty))
    }

    @Test func data64KiBPayload() throws {
        try expectFixture(
            buildData(streamID: 5, payload: Data(repeating: 0, count: 64 * 1024)),
            bytes: Fixtures.data64KiB
        )
    }

    @Test func closeStreamOne() throws {
        try expectFixture(buildClose(streamID: 1), bytes: Data(Fixtures.close1))
    }

    @Test func resetProtocolError() throws {
        try expectFixture(
            buildReset(streamID: 1, reason: .protocolError),
            bytes: Data(Fixtures.resetProtocolError)
        )
    }

    @Test func resetFlowControlError() throws {
        try expectFixture(
            buildReset(streamID: 7, reason: .flowControlError),
            bytes: Data(Fixtures.resetFlowControlError)
        )
    }

    @Test func window64KiBCredit() throws {
        try expectFixture(buildWindow(streamID: 1, credit: 0x0001_0000), bytes: Data(Fixtures.window64KiB))
    }

    @Test func pingRoundTrip() throws {
        try expectFixture(buildPing(nonce: Data([1, 2, 3, 4, 5, 6, 7, 8])), bytes: Data(Fixtures.ping))
    }

    @Test func pongRoundTrip() throws {
        try expectFixture(buildPong(nonce: Data([1, 2, 3, 4, 5, 6, 7, 8])), bytes: Data(Fixtures.pong))
    }

    @Test func dataFourBytes() throws {
        try expectFixture(
            buildData(streamID: 9, payload: Data([0x01, 0x02, 0x03, 0x04])),
            bytes: Data(Fixtures.dataFourBytes)
        )
    }

    private func expectFixture(_ frame: Frame, bytes: Data) throws {
        let encoded = try encodeFrame(frame)
        #expect(encoded == bytes)

        var decoder = FrameDecoder()
        decoder.feed(bytes)
        let decoded = try #require(try decoder.next())
        #expect(decoded == frame)
        #expect(try decoder.next() == nil)
    }
}

@Suite("FrameCodecValidation")
struct FrameCodecValidationTests {
    @Test func payloadTooLargeThrows() {
        expectThrows(.payloadTooLarge) {
            _ = try encodeFrame(Frame(
                streamID: 1,
                flags: FrameFlags.data.rawValue,
                payload: Data(repeating: 0, count: FramingLimits.maxPayload + 1)
            ))
        }
    }

    @Test func reservedBitsThrow() {
        expectThrows(.reservedBitsSet) {
            try validateFlags(0xe0)
        }
    }

    @Test func noPrimaryFlagThrows() {
        expectThrows(.noPrimaryFlag) {
            try validateFlags(0x00)
        }
    }

    @Test func openResetThrows() {
        expectThrows(.invalidFlagCombination) {
            try validateFlags(FrameFlags.open.rawValue | FrameFlags.reset.rawValue)
        }
    }

    @Test func openDataCloseThrows() {
        expectThrows(.invalidFlagCombination) {
            try validateFlags(
                FrameFlags.open.rawValue |
                FrameFlags.data.rawValue |
                FrameFlags.close.rawValue
            )
        }
    }

    @Test func pingDataThrows() {
        expectThrows(.invalidFlagCombination) {
            try validateFlags(FrameFlags.ping.rawValue | FrameFlags.data.rawValue)
        }
    }

    @Test func invalidControlNonceLengthThrows() {
        expectThrows(.lengthMismatch) {
            _ = try buildPing(nonce: Data([0x01]))
        }
    }
}

@Suite("FrameDecoderIncremental")
struct FrameDecoderIncrementalTests {
    @Test func threeFramesInOneByteChunks() throws {
        let frames = [
            buildOpen(streamID: 1),
            buildData(streamID: 1, payload: Data([0x41])),
            buildClose(streamID: 1)
        ]
        let bytes = try frames.reduce(into: Data()) { partial, frame in
            partial.append(try encodeFrame(frame))
        }

        var decoded: [Frame] = []
        var decoder = FrameDecoder()
        for byte in bytes {
            decoder.feed(Data([byte]))
            while let frame = try decoder.next() {
                decoded.append(frame)
            }
        }

        #expect(decoded == frames)
        #expect(try decoder.next() == nil)
    }

    @Test func oneMiBOneByteChunksUnder200Milliseconds() throws {
        let frame = buildData(streamID: 1, payload: Data(repeating: 0, count: 1 << 20))
        let bytes = try encodeFrame(frame)
        let chunks = bytes.map { Data([$0]) }
        var decoder = FrameDecoder()
        let clock = ContinuousClock()

        let elapsed = try clock.measure {
            for chunk in chunks {
                decoder.feed(chunk)
            }
            let decoded = try #require(try decoder.next())
            #expect(decoded == frame)
            #expect(try decoder.next() == nil)
        }

        #expect(elapsed < .milliseconds(200))
    }
}

private func expectThrows<T>(_ expected: FramingError, _ operation: () throws -> T) {
    do {
        _ = try operation()
        Issue.record("Expected \(expected)")
    } catch let error as FramingError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected), got \(error)")
    }
}
