// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import os

private let logger = Logger(subsystem: "app.solstone.observer.spl", category: "loopback")

public enum LoopbackProxyError: Error, Sendable, Equatable {
    case listenerMissingPort
    case listenerFailed(String)
}

public actor LoopbackProxy {
    private let tunnel: TunnelSession
    private var listener: NWListener?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    public init(tunnel: TunnelSession) {
        self.tunnel = tunnel
    }

    public func start() async throws -> UInt16 {
        if let port = listener?.port?.rawValue {
            return port
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let waiter = LoopbackListenerReadyWaiter()
        let tunnel = self.tunnel

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    waiter.complete(.success(port))
                } else {
                    waiter.complete(.failure(LoopbackProxyError.listenerMissingPort))
                }
            case .failed(let error):
                waiter.complete(.failure(LoopbackProxyError.listenerFailed(error.localizedDescription)))
            case .cancelled:
                break
            case .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let proxy = self else {
                connection.cancel()
                return
            }
            let id = UUID()
            let task = Task {
                await Self.handle(connection: connection, tunnel: tunnel)
                await proxy.removeConnectionTask(id)
            }
            Task {
                await proxy.storeConnectionTask(task, id: id)
            }
        }

        self.listener = listener
        listener.start(queue: .global(qos: .utility))
        return try await waiter.wait()
    }

    public func stop() async {
        listener?.cancel()
        listener = nil

        let tasks = connectionTasks.values
        connectionTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func storeConnectionTask(_ task: Task<Void, Never>, id: UUID) {
        connectionTasks[id] = task
    }

    private func removeConnectionTask(_ id: UUID) {
        connectionTasks[id] = nil
    }

    private nonisolated static func handle(connection: NWConnection, tunnel: TunnelSession) async {
        var bytesIn = 0
        var bytesOut = 0
        defer {
            logger.debug("closed connection bytes_in=\(bytesIn, privacy: .public) bytes_out=\(bytesOut, privacy: .public)")
            connection.cancel()
        }

        connection.start(queue: .global(qos: .utility))
        let stream: MuxStream
        do {
            stream = try await tunnel.openStream()
        } catch {
            return
        }

        await withTaskGroup(of: LoopbackPumpStats.self) { group in
            group.addTask {
                let bytes = await pumpTCP(connection, to: stream)
                return LoopbackPumpStats(bytesIn: bytes, bytesOut: 0)
            }
            group.addTask {
                let bytes = await pumpStream(stream, to: connection)
                return LoopbackPumpStats(bytesIn: 0, bytesOut: bytes)
            }

            for await stats in group {
                bytesIn += stats.bytesIn
                bytesOut += stats.bytesOut
            }
        }
    }

    private nonisolated static func pumpTCP(_ connection: NWConnection, to stream: MuxStream) async -> Int {
        var bytes = 0
        while !Task.isCancelled {
            do {
                let (chunk, isComplete) = try await receive(from: connection)
                if let chunk, !chunk.isEmpty {
                    bytes += chunk.count
                    try await stream.write(chunk)
                }
                if isComplete || chunk == nil {
                    try? await stream.close()
                    return bytes
                }
            } catch {
                await stream.reset(reason: .internalError)
                return bytes
            }
        }
        await stream.reset(reason: .normal)
        return bytes
    }

    private nonisolated static func pumpStream(_ stream: MuxStream, to connection: NWConnection) async -> Int {
        var bytes = 0
        do {
            for try await chunk in stream.inbound {
                bytes += chunk.count
                try await send(chunk, to: connection)
            }
            try? await sendEOF(to: connection)
        } catch {
            connection.cancel()
        }
        return bytes
    }

    private nonisolated static func receive(from connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (data, isComplete))
            }
        }
    }

    private nonisolated static func send(_ data: Data, to connection: NWConnection) async throws {
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

    private nonisolated static func sendEOF(to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
}

private struct LoopbackPumpStats: Sendable {
    var bytesIn: Int
    var bytesOut: Int
}

private final class LoopbackListenerReadyWaiter: @unchecked Sendable {
    // why: NWListener invokes state callbacks on a dispatch queue while start() awaits; NSLock guards one-shot result delivery.
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
