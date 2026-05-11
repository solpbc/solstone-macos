// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import Security

actor MockRelay {
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    init() throws {}

    func start() async throws -> URL {
        if let port = listener?.port?.rawValue {
            return URL(string: "http://127.0.0.1:\(port)")!
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let waiter = MockRelayListenerReadyWaiter()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    waiter.complete(.success(port))
                } else {
                    waiter.complete(.failure(MockRelayError.listenerMissingPort))
                }
            case .failed(let error):
                waiter.complete(.failure(error))
            case .cancelled, .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: .global(qos: .utility))
        let port = try await waiter.wait()
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .utility))
        Task {
            await handle(connection)
        }
    }

    private nonisolated func handle(_ connection: NWConnection) async {
        do {
            let request = try await MockHTTPConnection.readRequest(from: connection)
            guard request.method == "POST", request.path == "/enroll/device" else {
                try await MockHTTPConnection.send(status: 404, body: #"{"error":"not_found"}"#, to: connection)
                connection.cancel()
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  json["instance_id"] as? String != nil,
                  json["client_cert"] as? String != nil,
                  json["home_attestation"] as? String != nil else {
                try await MockHTTPConnection.send(status: 400, body: #"{"error":"bad_request"}"#, to: connection)
                connection.cancel()
                return
            }
            let response = [
                "device_token": Self.randomHex(byteCount: 32),
                "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(24 * 60 * 60)),
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            try await MockHTTPConnection.send(status: 200, body: String(data: data, encoding: .utf8)!, to: connection)
            connection.cancel()
        } catch {
            connection.cancel()
        }
    }

    private nonisolated static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum MockRelayError: Error {
    case listenerMissingPort
}

struct MockHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum MockHTTPConnection {
    static let maxBodySize = 16 * 1024 * 1024

    static func readRequest(from connection: NWConnection) async throws -> MockHTTPRequest {
        var buffer = Data()
        while !buffer.containsHeaderTerminator {
            guard let chunk = try await receive(from: connection), !chunk.isEmpty else {
                throw MockHTTPError.closed
            }
            buffer.append(chunk)
            if buffer.count > maxBodySize {
                throw MockHTTPError.bodyTooLarge
            }
        }

        let headerEnd = buffer.headerTerminatorRange!.lowerBound
        let bodyStart = buffer.headerTerminatorRange!.upperBound
        let headerData = buffer[..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw MockHTTPError.invalidRequest
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw MockHTTPError.invalidRequest
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw MockHTTPError.invalidRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            throw MockHTTPError.chunkedUnsupported
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= maxBodySize else {
            throw MockHTTPError.bodyTooLarge
        }

        var body = Data(buffer[bodyStart...])
        while body.count < contentLength {
            guard let chunk = try await receive(from: connection), !chunk.isEmpty else {
                throw MockHTTPError.closed
            }
            body.append(chunk)
        }
        if body.count > contentLength {
            body = Data(body.prefix(contentLength))
        }
        return MockHTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    static func send(status: Int, body: String, to connection: NWConnection) async throws {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        try await send(Data(response.utf8), to: connection)
    }

    static func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receive(from connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                continuation.resume(returning: isComplete ? nil : Data())
            }
        }
    }
}

enum MockHTTPError: Error {
    case bodyTooLarge
    case chunkedUnsupported
    case closed
    case invalidRequest
}

private extension Data {
    var headerTerminatorRange: Range<Data.Index>? {
        range(of: Data("\r\n\r\n".utf8))
    }

    var containsHeaderTerminator: Bool {
        headerTerminatorRange != nil
    }
}

private final class MockRelayListenerReadyWaiter: @unchecked Sendable {
    // why: NWListener state callbacks run on a dispatch queue while start() awaits; NSLock serializes one-shot completion.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var result: Result<UInt16, Error>?

    func wait() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let result: Result<UInt16, Error>? = lock.withLock {
                if let result = self.result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func complete(_ result: Result<UInt16, Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else {
                return nil as CheckedContinuation<UInt16, Error>?
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
