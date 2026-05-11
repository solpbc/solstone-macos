// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
@testable import SPLTunnel

private let serverQueue = DispatchQueue(label: "app.solstone.observer.spl.tests.echo")

actor TCPEchoServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: serverQueue)
        echo(connection)
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard error == nil, let data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }
            guard let server = self else {
                return
            }
            connection.send(content: data, completion: .contentProcessed { _ in
                Task {
                    await server.echo(connection)
                }
            })
        }
    }
}

actor WebSocketEchoServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?
    private(set) var authorizationHeader: String?
    private let textOnConnect: String?

    init(textOnConnect: String? = nil) {
        self.textOnConnect = textOnConnect
    }

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(serverQueue) { [weak self] _, headers in
            if let authorization = headers.first(where: { $0.name.lowercased() == "authorization" })?.value {
                Task {
                    await self?.setAuthorizationHeader(authorization)
                }
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
        authorizationHeader = nil
    }

    private func setAuthorizationHeader(_ value: String) {
        authorizationHeader = value
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: serverQueue)
        if let textOnConnect {
            sendText(textOnConnect, on: connection)
        } else {
            receiveMessage(on: connection)
        }
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "echo", metadata: [metadata])
            guard let server = self else {
                return
            }
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
                Task {
                    await server.receiveMessage(on: connection)
                }
            })
        }
    }

    private func sendText(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

actor WebSocketFailingServer {
    private let statusCode: Int
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: serverQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [statusCode] _, _, _, _ in
            let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            let response = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Length: 0\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private final class ListenerReadyWaiter: @unchecked Sendable {
    // why: NWListener invokes state callbacks concurrently with test tasks; NSLock provides one-shot resume.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result: Result<Void, Error>? = lock.withLock {
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

    func complete(_ result: Result<Void, Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else {
                return nil as CheckedContinuation<Void, Error>?
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private func startAndWaitForListenerReady(_ listener: NWListener) async throws {
    let waiter = ListenerReadyWaiter()
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            waiter.complete(.success(()))
        case .failed(let error):
            waiter.complete(.failure(error))
        case .cancelled:
            waiter.complete(.failure(DialError.connectionFailed("listener cancelled")))
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }
    listener.start(queue: serverQueue)
    try await waiter.wait()
}
