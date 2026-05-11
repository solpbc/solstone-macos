// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Network
import os
import Security

private let logger = Logger(subsystem: "app.solstone.observer.spl", category: "tls")
private let tlsQueue = DispatchQueue(label: "app.solstone.observer.spl.tls")

public enum InnerTLSError: Error, Equatable, Sendable {
    case invalidPort(Int)
    case identityAssemblyFailed
    case invalidCertificate
    case invalidPrivateKey
    case peerNotPinned
    case handshakeFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case closed
}

public actor InnerTLS {
    public nonisolated var inbound: AsyncThrowingStream<Data, Error> {
        inboundStream
    }

    private let connection: NWConnection
    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let relayTransport: (any ByteTransport)?
    private var listener: NWListener?
    private var peerConnection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var pumpTasks: [Task<Void, Never>] = []
    private var isClosed = false

    private init(
        connection: NWConnection,
        relayTransport: (any ByteTransport)? = nil,
        listener: NWListener? = nil,
        peerConnection: NWConnection? = nil,
        pumpTasks: [Task<Void, Never>] = []
    ) {
        self.connection = connection
        self.relayTransport = relayTransport
        self.listener = listener
        self.peerConnection = peerConnection
        self.pumpTasks = pumpTasks

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.inboundStream = AsyncThrowingStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    public static func connectLAN(host: String, port: Int, pairing: StoredPairing) async throws -> InnerTLS {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), 1...65535 ~= port else {
            throw InnerTLSError.invalidPort(port)
        }

        let verifyFailure = TLSVerifyFailure()
        let options = try makeTLSOptions(pairing: pairing, verifyFailure: verifyFailure)
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let startedAt = ContinuousClock.now
        do {
            try await startAndWaitReady(connection)
        } catch let error as InnerTLSError {
            connection.cancel()
            if let reason = verifyFailure.reason {
                throw reason
            }
            throw error
        } catch {
            connection.cancel()
            if let reason = verifyFailure.reason {
                throw reason
            }
            throw InnerTLSError.handshakeFailed(error.localizedDescription)
        }

        let elapsed = startedAt.duration(to: .now).milliseconds
        logger.debug("handshake transport=\("lan", privacy: .public) duration_ms=\(elapsed, privacy: .public)")

        let tls = InnerTLS(connection: connection)
        await tls.startReceiveLoop()
        return tls
    }

    public static func connectViaTransport(transport: any ByteTransport, pairing: StoredPairing) async throws -> InnerTLS {
        let verifyFailure = TLSVerifyFailure()
        let options = try makeTLSOptions(pairing: pairing, verifyFailure: verifyFailure)
        let listener = try NWListener(using: .tcp, on: .any)
        let acceptor = OneShotConnectionAcceptor()
        listener.newConnectionHandler = { connection in
            acceptor.complete(connection)
        }
        try await startAndWaitReady(listener)
        guard let port = listener.port else {
            listener.cancel()
            await transport.close()
            throw InnerTLSError.handshakeFailed("loopback listener did not bind")
        }

        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        let connectionWaiter = startAndReturnReadyWaiter(connection)

        let peer = try await acceptor.wait()
        try await startAndWaitReady(peer)

        let pumps = makePumpTasks(transport: transport, peer: peer)
        let startedAt = ContinuousClock.now
        do {
            try await connectionWaiter.wait()
        } catch let error as InnerTLSError {
            pumps.forEach { $0.cancel() }
            peer.cancel()
            connection.cancel()
            listener.cancel()
            await transport.close()
            if let reason = verifyFailure.reason {
                throw reason
            }
            throw error
        } catch {
            pumps.forEach { $0.cancel() }
            peer.cancel()
            connection.cancel()
            listener.cancel()
            await transport.close()
            if let reason = verifyFailure.reason {
                throw reason
            }
            throw InnerTLSError.handshakeFailed(error.localizedDescription)
        }

        let elapsed = startedAt.duration(to: .now).milliseconds
        logger.debug("handshake transport=\(transport.transportKind, privacy: .public) duration_ms=\(elapsed, privacy: .public)")

        let tls = InnerTLS(
            connection: connection,
            relayTransport: transport,
            listener: listener,
            peerConnection: peer,
            pumpTasks: pumps
        )
        await tls.startReceiveLoop()
        return tls
    }

    public func send(_ plaintext: Data) async throws {
        guard !isClosed else {
            throw InnerTLSError.closed
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: plaintext, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: InnerTLSError.sendFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        receiveTask?.cancel()
        for task in pumpTasks {
            task.cancel()
        }
        peerConnection?.cancel()
        listener?.cancel()
        connection.cancel()
        await relayTransport?.close()
        inboundContinuation.finish()
        logger.debug("closed reason=\("normalShutdown", privacy: .public)")
    }

    private func startReceiveLoop() {
        receiveTask = Task { [connection, inboundContinuation] in
            do {
                while !Task.isCancelled {
                    guard let data = try await receivePlaintext(from: connection) else {
                        inboundContinuation.finish()
                        return
                    }
                    inboundContinuation.yield(data)
                }
                inboundContinuation.finish()
            } catch {
                inboundContinuation.finish(throwing: InnerTLSError.receiveFailed(error.localizedDescription))
            }
        }
    }

    private static func makeTLSOptions(pairing: StoredPairing, verifyFailure: TLSVerifyFailure) throws -> NWProtocolTLS.Options {
        let caCertificates: [SecCertificate]
        do {
            caCertificates = try CertChain.certificates(fromPEM: pairing.caChainPEM)
        } catch {
            throw InnerTLSError.invalidCertificate
        }

        let identity = try makeIdentity(pairing: pairing)
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_local_identity(secOptions, identity)
        // why: SPLTunnel pins its private CA; the verify block replaces default hostname validation.
        sec_protocol_options_set_verify_block(secOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(secTrust, caCertificates as CFArray)
            SecTrustSetAnchorCertificatesOnly(secTrust, true)
            var error: CFError?
            let trusted = SecTrustEvaluateWithError(secTrust, &error)
            if !trusted {
                verifyFailure.set(.peerNotPinned)
            }
            complete(trusted)
        }, tlsQueue)
        return options
    }

    static func makeIdentity(pairing: StoredPairing) throws -> sec_identity_t {
        let certificates: [SecCertificate]
        do {
            certificates = try CertChain.certificates(fromPEM: pairing.clientCertPEM)
        } catch {
            throw InnerTLSError.invalidCertificate
        }
        guard let leaf = certificates.first else {
            throw InnerTLSError.invalidCertificate
        }

        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try CryptoCSR.pkcs8PEMToPrivateKey(pairing.clientKeyPEM)
        } catch {
            throw InnerTLSError.invalidPrivateKey
        }

        let keyData = Data(privateKey.publicKey.x963Representation + privateKey.rawRepresentation)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &keyError) else {
            throw InnerTLSError.invalidPrivateKey
        }
        guard let identity = SecIdentityCreate(nil, leaf, secKey) else {
            throw InnerTLSError.identityAssemblyFailed
        }

        let intermediates = Array(certificates.dropFirst())
        if !intermediates.isEmpty, let wrapped = sec_identity_create_with_certificates(identity, intermediates as CFArray) {
            return wrapped
        }
        guard let wrapped = sec_identity_create(identity) else {
            throw InnerTLSError.identityAssemblyFailed
        }
        return wrapped
    }
}

private final class TLSVerifyFailure: @unchecked Sendable {
    // why: Security verify callbacks run on a dispatch queue while factories await NWConnection state.
    private let lock = NSLock()
    private var value: InnerTLSError?

    var reason: InnerTLSError? {
        lock.withLock { value }
    }

    func set(_ reason: InnerTLSError) {
        lock.withLock {
            if value == nil {
                value = reason
            }
        }
    }
}

private final class ConnectionReadyWaiter: @unchecked Sendable {
    // why: NWConnection/NWListener state callbacks race cancellation; NSLock gives one-shot resume.
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

private final class OneShotConnectionAcceptor: @unchecked Sendable {
    // why: NWListener accepts on a queue while the factory awaits; NSLock guards one accepted connection.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWConnection, Error>?
    private var connection: NWConnection?

    func wait() async throws -> NWConnection {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
            let connection: NWConnection? = lock.withLock {
                if let connection = self.connection {
                    return connection
                }
                self.continuation = continuation
                return nil
            }
            if let connection {
                continuation.resume(returning: connection)
            }
        }
    }

    func complete(_ connection: NWConnection) {
        let continuation = lock.withLock {
            guard self.connection == nil else {
                connection.cancel()
                return nil as CheckedContinuation<NWConnection, Error>?
            }
            self.connection = connection
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: connection)
    }
}

private func startAndWaitReady(_ connection: NWConnection) async throws {
    let waiter = startAndReturnReadyWaiter(connection)
    try await withTaskCancellationHandler {
        try await waiter.wait()
    } onCancel: {
        connection.cancel()
    }
}

private func startAndReturnReadyWaiter(_ connection: NWConnection) -> ConnectionReadyWaiter {
    let waiter = ConnectionReadyWaiter()
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            waiter.complete(.success(()))
        case .failed(let error):
            waiter.complete(.failure(InnerTLSError.handshakeFailed(error.localizedDescription)))
        case .cancelled:
            waiter.complete(.failure(InnerTLSError.closed))
        case .waiting(let error):
            waiter.complete(.failure(InnerTLSError.handshakeFailed(error.localizedDescription)))
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }
    connection.start(queue: tlsQueue)
    return waiter
}

private func startAndWaitReady(_ listener: NWListener) async throws {
    let waiter = ConnectionReadyWaiter()
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            waiter.complete(.success(()))
        case .failed(let error):
            waiter.complete(.failure(InnerTLSError.handshakeFailed(error.localizedDescription)))
        case .cancelled:
            waiter.complete(.failure(InnerTLSError.closed))
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }
    listener.start(queue: tlsQueue)
    try await withTaskCancellationHandler {
        try await waiter.wait()
    } onCancel: {
        listener.cancel()
    }
}

private func makePumpTasks(transport: any ByteTransport, peer: NWConnection) -> [Task<Void, Never>] {
    let inbound = Task {
        do {
            while !Task.isCancelled {
                guard let data = try await transport.receive() else {
                    peer.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
                    return
                }
                try await sendRaw(data, to: peer)
            }
        } catch {
            peer.cancel()
            await transport.close()
        }
    }

    let outbound = Task {
        do {
            while !Task.isCancelled {
                guard let data = try await receiveRaw(from: peer) else {
                    await transport.close()
                    return
                }
                try await transport.send(data)
            }
        } catch {
            peer.cancel()
            await transport.close()
        }
    }

    return [inbound, outbound]
}

private func sendRaw(_ data: Data, to connection: NWConnection) async throws {
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

private func receiveRaw(from connection: NWConnection) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            if let error {
                continuation.resume(throwing: error)
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

private func receivePlaintext(from connection: NWConnection) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            if let error {
                continuation.resume(throwing: error)
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

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
