// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public protocol LANPairTransport: Sendable {
    func send(
        host: String,
        port: Int,
        caFingerprintBytes: [UInt8],
        requestBytes: Data
    ) async throws -> (status: Int, body: Data)
}

enum CertlessPairError: Error, Equatable, Sendable {
    case closedBeforeStatus
    case malformedResponse
}

public struct CertlessPairExchange: LANPairTransport {
    public init() {}

    public func send(
        host: String,
        port: Int,
        caFingerprintBytes: [UInt8],
        requestBytes: Data
    ) async throws -> (status: Int, body: Data) {
        let tls = try await InnerTLS.connectLANCertless(host: host, port: port, caFingerprintBytes: caFingerprintBytes)
        let mux = Multiplexer(sink: { data in
            try await tls.send(data)
        }, role: .dialer)
        let pump = Task {
            do {
                for try await chunk in tls.inbound {
                    try await mux.feedInbound(chunk)
                }
                await mux.tearDown(reason: .transportFailure)
            } catch {
                await mux.tearDown(reason: .transportFailure)
            }
        }

        do {
            let stream = try await mux.openStream()
            try await stream.write(requestBytes)
            let response = try await Self.readResponse(from: stream)
            pump.cancel()
            await tls.close()
            await mux.tearDown(reason: .normalShutdown)
            return response
        } catch {
            pump.cancel()
            await tls.close()
            await mux.tearDown(reason: .transportFailure)
            throw error
        }
    }

    static func encodeRequest(host: String, path: String, jsonBody: Data) -> Data {
        var request = Data()
        request.append(Data("POST \(path) HTTP/1.1\r\n".utf8))
        request.append(Data("Host: \(host)\r\n".utf8))
        request.append(Data("Content-Type: application/json\r\n".utf8))
        request.append(Data("Content-Length: \(jsonBody.count)\r\n".utf8))
        request.append(Data("\r\n".utf8))
        request.append(jsonBody)
        return request
    }

    static func parseResponse(_ data: Data) throws -> (status: Int, body: Data)? {
        let lineBreak = Data("\r\n".utf8)
        guard let statusLineRange = data.range(of: lineBreak) else {
            return nil
        }

        let statusLine = data[..<statusLineRange.lowerBound]
        let status = try parseStatusLine(statusLine)
        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: headerTerminator) else {
            return nil
        }

        let headerData: Data.SubSequence
        if headerRange.lowerBound == statusLineRange.lowerBound {
            headerData = data[statusLineRange.upperBound..<statusLineRange.upperBound]
        } else {
            guard headerRange.lowerBound >= statusLineRange.upperBound else {
                throw CertlessPairError.malformedResponse
            }
            headerData = data[statusLineRange.upperBound..<headerRange.lowerBound]
        }
        let contentLength = try parseContentLength(headerData)
        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard data.endIndex >= bodyEnd else {
            return nil
        }

        return (status: status, body: Data(data[bodyStart..<bodyEnd]))
    }

    private static func readResponse(from stream: MuxStream) async throws -> (status: Int, body: Data) {
        var buffer = Data()
        do {
            for try await chunk in stream.inbound {
                buffer.append(chunk)
                if let response = try parseResponse(buffer) {
                    return response
                }
            }
        } catch {
            throw incompleteResponseError(buffer: buffer)
        }
        throw incompleteResponseError(buffer: buffer)
    }

    private static func incompleteResponseError(buffer: Data) -> CertlessPairError {
        buffer.isEmpty ? .closedBeforeStatus : .malformedResponse
    }

    private static func parseStatusLine(_ data: Data.SubSequence) throws -> Int {
        guard let line = String(data: data, encoding: .utf8) else {
            throw CertlessPairError.malformedResponse
        }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              parts[0].hasPrefix("HTTP/"),
              let status = Int(parts[1]),
              100...999 ~= status else {
            throw CertlessPairError.malformedResponse
        }
        return status
    }

    private static func parseContentLength(_ data: Data.SubSequence) throws -> Int {
        guard let headers = String(data: data, encoding: .utf8) else {
            throw CertlessPairError.malformedResponse
        }
        var contentLength: Int?
        for line in headers.components(separatedBy: "\r\n") where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw CertlessPairError.malformedResponse
            }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "transfer-encoding", value.lowercased().contains("chunked") {
                throw CertlessPairError.malformedResponse
            }
            if name == "content-length" {
                guard contentLength == nil,
                      let length = Int(value),
                      length >= 0 else {
                    throw CertlessPairError.malformedResponse
                }
                contentLength = length
            }
        }
        guard let contentLength else {
            throw CertlessPairError.malformedResponse
        }
        return contentLength
    }
}
