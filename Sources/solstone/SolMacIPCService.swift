// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Network
import os
import SolstoneCore

@MainActor
public final class SolMacIPCService {
    private let responder: SolMacResponder
    private let socketURL: URL
    private let queue = DispatchQueue(label: "app.solstone.observer.ipc")
    private let readyState = ReadyState()
    private var listener: NWListener?
    private var activeHandlers: [UUID: ConnectionHandler] = [:]

    public init(responder: SolMacResponder, socketURL: URL = SolMacIPCConstants.socketURL) {
        self.responder = responder
        self.socketURL = socketURL
    }

    public func start() {
        guard listener == nil else { return }

        do {
            let parentURL = socketURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentURL.path)
            try? FileManager.default.removeItem(at: socketURL)

            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: socketURL.path)
            let newListener = try NWListener(using: parameters)
            readyState.setReady(false)

            newListener.stateUpdateHandler = { [socketURL, readyState] (state: NWListener.State) in
                switch state {
                case .ready:
                    if chmod(socketURL.path, mode_t(0o600)) == 0 {
                        readyState.setReady(true)
                        Logger.general.info("ipc listener started at \(socketURL.path, privacy: .public)")
                    } else {
                        let message = String(cString: strerror(errno))
                        Logger.general.error("ipc chmod failed for \(socketURL.path, privacy: .public): \(message, privacy: .private)")
                    }
                case .failed(let error):
                    Logger.general.error("ipc listener failed: \(String(describing: error), privacy: .private)")
                case .cancelled:
                    Logger.general.info("ipc listener cancelled")
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self, readyState] (connection: NWConnection) in
                Task { @MainActor [weak self] in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    guard readyState.isReady else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }

            newListener.start(queue: queue)
            listener = newListener
        } catch {
            Logger.general.error("ipc listener start failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    public func stop() {
        readyState.setReady(false)
        listener?.cancel()
        listener = nil

        let handlers = activeHandlers.values
        activeHandlers.removeAll()
        for handler in handlers {
            Task {
                await handler.cancel()
            }
        }

        try? FileManager.default.removeItem(at: socketURL)
        Logger.general.info("ipc listener stopped at \(self.socketURL.path, privacy: .public)")
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let handler = ConnectionHandler(
            id: id,
            connection: connection,
            responder: responder,
            queue: queue
        )
        activeHandlers[id] = handler

        Task {
            await handler.run()
            let _: Void = await MainActor.run {
                self.activeHandlers.removeValue(forKey: id)
            }
        }
    }
}

private final class ReadyState: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    var isReady: Bool {
        lock.withLock { ready }
    }

    func setReady(_ ready: Bool) {
        lock.withLock {
            self.ready = ready
        }
    }
}

private actor ConnectionHandler {
    private let id: UUID
    private let connection: NWConnection
    private let responder: SolMacResponder
    private let queue: DispatchQueue

    init(id: UUID, connection: NWConnection, responder: SolMacResponder, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.responder = responder
        self.queue = queue
    }

    func run() async {
        connection.start(queue: queue)
        do {
            let line = try await receiveLine()
            let request = try IPCWire.decoder.decode(IPCRequest.self, from: line)
            let response = await responder.handle(request, isFirstResponseOnConnection: true)
            try await sendLine(try IPCWire.encoder.encode(response))
        } catch {
            Logger.general.debug("ipc connection \(self.id.uuidString, privacy: .public) ended: \(String(describing: error), privacy: .private)")
        }

        connection.cancel()
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveLine() async throws -> Data {
        var buffer = Data()

        while true {
            let chunk = try await receiveChunk()
            if let data = chunk.data {
                buffer.append(data)
            }

            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return buffer[..<newlineIndex]
            }

            if chunk.isComplete {
                throw ConnectionIOError.eof
            }
        }
    }

    private func receiveChunk() async throws -> (data: Data?, isComplete: Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data?, isComplete: Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func sendLine(_ data: Data) async throws {
        var framed = data
        framed.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private enum ConnectionIOError: Error {
        case eof
    }
}
