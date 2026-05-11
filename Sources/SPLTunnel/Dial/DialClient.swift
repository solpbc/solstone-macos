// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import os

private let logger = Logger(subsystem: "app.solstone.observer.spl", category: "dial")

public enum DialError: Error, Equatable, Sendable {
    case invalidPort(Int)
    case invalidRelayURL(String)
    case connectTimeout
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case unexpectedTextFrame
    case relayUnauthorized
    case relayInstanceUnknown
    case wsHandshakeFailed(httpStatus: Int?)
}

public enum DialClient {
    public static func dial(
        _ endpoint: TransportEndpoint,
        timeout: Duration = .seconds(5)
    ) async throws -> any ByteTransport {
        switch endpoint {
        case .lan(let host, let port, _):
            return try await dialLAN(host: host, port: port, timeout: timeout)
        case .relay(let endpoint, let instanceID, let deviceToken):
            return try await dialRelay(endpoint: endpoint, instanceID: instanceID, deviceToken: deviceToken, timeout: timeout)
        }
    }

    private static func dialLAN(host: String, port: Int, timeout: Duration) async throws -> LANTransport {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), 1...65535 ~= port else {
            throw DialError.invalidPort(port)
        }

        let startedAt = ContinuousClock.now
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let transport = LANTransport(connection: connection)

        do {
            try await withTimeout(timeout) {
                try await startAndWaitReady(connection)
            }
            let elapsed = startedAt.duration(to: .now).milliseconds
            logger.debug("connected transport=\("lan", privacy: .public) duration_ms=\(elapsed, privacy: .public)")
            return transport
        } catch DialError.connectTimeout {
            await transport.close()
            throw DialError.connectTimeout
        } catch {
            await transport.close()
            throw DialError.connectionFailed(error.localizedDescription)
        }
    }

    private static func dialRelay(
        endpoint: URL,
        instanceID: String,
        deviceToken: String,
        timeout: Duration
    ) async throws -> RelayWSTransport {
        let transport = try RelayWSTransport(endpoint: endpoint, instanceID: instanceID, deviceToken: deviceToken)
        let startedAt = ContinuousClock.now

        do {
            try await withTimeout(timeout) {
                try await transport.open()
            }
            let elapsed = startedAt.duration(to: .now).milliseconds
            logger.debug("connected transport=\("relay", privacy: .public) duration_ms=\(elapsed, privacy: .public)")
            return transport
        } catch {
            await transport.close()
            throw error
        }
    }
}

public actor LANTransport: ByteTransport {
    public nonisolated let transportKind = "lan"

    private let connection: NWConnection
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    public func send(_ data: Data) async throws {
        guard !closed else {
            throw DialError.sendFailed("transport closed")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: DialError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> Data? {
        guard !closed else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: DialError.receiveFailed(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    public func close() async {
        guard !closed else {
            return
        }
        closed = true
        connection.cancel()
    }
}

public actor RelayWSTransport: ByteTransport {
    public nonisolated let transportKind = "relay"

    private let session: URLSession
    private let delegate: WebSocketOpenDelegate
    private let task: URLSessionWebSocketTask
    private var closed = false

    init(endpoint: URL, instanceID: String, deviceToken: String) throws {
        let url = endpoint
            .appending(path: "session/dial")
            .appending(queryItems: [.init(name: "instance", value: instanceID)])
        guard url.scheme == "ws" || url.scheme == "wss" else {
            throw DialError.invalidRelayURL(endpoint.absoluteString)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent(), forHTTPHeaderField: "User-Agent")

        let delegate = WebSocketOpenDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        delegate.attach(task: task)

        self.session = session
        self.delegate = delegate
        self.task = task
    }

    func open() async throws {
        task.resume()
        try await delegate.waitForOpen()
    }

    public func send(_ data: Data) async throws {
        guard !closed else {
            throw DialError.sendFailed("transport closed")
        }
        do {
            try await task.send(.data(data))
        } catch {
            throw DialError.sendFailed(error.localizedDescription)
        }
    }

    public func receive() async throws -> Data? {
        guard !closed else {
            return nil
        }
        do {
            switch try await task.receive() {
            case .data(let data):
                return data
            case .string:
                throw DialError.unexpectedTextFrame
            @unknown default:
                throw DialError.receiveFailed("unknown websocket message")
            }
        } catch let error as DialError {
            throw error
        } catch {
            throw DialError.receiveFailed(error.localizedDescription)
        }
    }

    public func close() async {
        guard !closed else {
            return
        }
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private static func userAgent() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return "solstone-macos/\(version)"
    }
}

// why: URLSession invokes delegate callbacks outside actor isolation; access is guarded by NSLock.
final class WebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private weak var task: URLSessionTask?

    func attach(task: URLSessionTask) {
        lock.withLock {
            self.task = task
        }
    }

    func waitForOpen() async throws {
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

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        complete(.success(()))
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else {
            return
        }
        complete(.failure(Self.mapFailure(error: error, task: task)))
    }

    private func complete(_ result: Result<Void, Error>) {
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

    private static func mapFailure(error: any Error, task: URLSessionTask) -> DialError {
        let nsError = error as NSError
        let response = (task.response as? HTTPURLResponse)
            ?? (nsError.userInfo["NSErrorFailingURLResponseKey"] as? HTTPURLResponse)

        guard let status = response?.statusCode else {
            return .connectionFailed(error.localizedDescription)
        }

        switch status {
        case 401, 403:
            return .relayUnauthorized
        case 404:
            return .relayInstanceUnknown
        default:
            return .wsHandshakeFailed(httpStatus: status)
        }
    }
}

private final class ConnectionReadyWaiter: @unchecked Sendable {
    // why: NWConnection state callbacks may race cancellation; NSLock ensures exactly one continuation resume.
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

private func startAndWaitReady(_ connection: NWConnection) async throws {
    let waiter = ConnectionReadyWaiter()
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            waiter.complete(.success(()))
        case .failed(let error):
            waiter.complete(.failure(DialError.connectionFailed(error.localizedDescription)))
        case .cancelled:
            waiter.complete(.failure(DialError.connectionFailed("cancelled")))
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            break
        }
    }
    connection.start(queue: .global(qos: .utility))
    try await withTaskCancellationHandler {
        try await waiter.wait()
    } onCancel: {
        connection.cancel()
    }
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw DialError.connectTimeout
        }

        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
