// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SPLTunnel

@Suite("CertlessPairExchange")
struct CertlessPairExchangeTests {
    @Test func frameCodecAcceptsCombinedOpenDataCapability() throws {
        let payload = Data([0x41, 0x42])
        let encoded = try encodeFrame(Frame(
            streamID: 1,
            flags: FrameFlags.open.rawValue | FrameFlags.data.rawValue,
            payload: payload
        ))

        #expect(encoded == Data(hex: "00000001030000024142"))

        var decoder = FrameDecoder()
        decoder.feed(encoded)
        #expect(try decoder.next() == Frame(streamID: 1, flags: 0x03, payload: payload))
        #expect(try decoder.next() == nil)
    }

    @Test func realMultiplexerEmitsOpenThenDataForPairRequest() async throws {
        let captured = LockedData()
        let mux = Multiplexer(sink: { data in
            captured.append(data)
        }, role: .dialer)
        let requestBytes = CertlessPairExchange.encodeRequest(
            host: "10.0.0.5",
            path: "/app/network/pair",
            jsonBody: try Self.sortedBody()
        )

        let stream = try await mux.openStream()
        try await stream.write(requestBytes)

        #expect(captured.value == Data(hex: Self.expectedMuxRequestHex))
    }

    @Test func parseResponseReturnsNilUntilBodyComplete() throws {
        let partialHeaders = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n".utf8)
        #expect(try CertlessPairExchange.parseResponse(partialHeaders) == nil)

        let partialBody = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\no".utf8)
        #expect(try CertlessPairExchange.parseResponse(partialBody) == nil)

        let full = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8)
        let parsed = try #require(try CertlessPairExchange.parseResponse(full))
        #expect(parsed.status == 200)
        #expect(parsed.body == Data("ok".utf8))
    }

    @Test func parseResponseRejectsMalformedAndMissingContentLength() {
        expectThrows(.malformedResponse) {
            _ = try CertlessPairExchange.parseResponse(Data("NOPE\r\nContent-Length: 0\r\n\r\n".utf8))
        }
        expectThrows(.malformedResponse) {
            _ = try CertlessPairExchange.parseResponse(Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
        }
        expectThrows(.malformedResponse) {
            _ = try CertlessPairExchange.parseResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        }
    }

    private static func sortedBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(FixedPairBody(
            nonce: "00112233445566778899aabbccddeeff",
            csr: "csr-pem",
            deviceLabel: "test phone"
        ))
    }

    private static let expectedMuxRequestHex = "000000010100000000000001020000bf504f5354202f6170702f6e6574776f726b2f7061697220485454502f312e310d0a486f73743a2031302e302e302e350d0a436f6e74656e742d547970653a206170706c69636174696f6e2f6a736f6e0d0a436f6e74656e742d4c656e6774683a2038380d0a0d0a7b22637372223a226373722d70656d222c226465766963655f6c6162656c223a22746573742070686f6e65222c226e6f6e6365223a223030313132323333343435353636373738383939616162626363646465656666227d"

    private func expectThrows(_ expected: CertlessPairError, _ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected \(expected)")
        } catch let error as CertlessPairError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got \(error)")
        }
    }
}

private struct FixedPairBody: Encodable {
    let nonce: String
    let csr: String
    let deviceLabel: String

    enum CodingKeys: String, CodingKey {
        case nonce
        case csr
        case deviceLabel = "device_label"
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.withLock { data }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }
}

private extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
