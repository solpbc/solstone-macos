// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import Security

private let logger = Logger(subsystem: "app.solstone.observer.spl", category: "mux")

public enum MuxError: Error, Equatable {
    case streamLimitExceeded
    case parityViolation
    case unknownStream
    case transportClosed
    case writeAfterClose
    case payloadTooLarge
    case protocolError
}

public enum TearDownReason: Sendable, Equatable {
    case normalShutdown
    case transportFailure
    case protocolError
}

public enum Role: Sendable {
    case dialer
    case listener
}

public actor Multiplexer {
    public nonisolated var keepaliveLost: AsyncStream<Void> {
        keepaliveLostStream
    }

    private let sink: @Sendable (Data) async throws -> Void
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let role: Role
    internal nonisolated let incomingStreams: AsyncStream<MuxStream>
    private let incomingContinuation: AsyncStream<MuxStream>.Continuation
    private let keepaliveLostStream: AsyncStream<Void>
    private let keepaliveLostContinuation: AsyncStream<Void>.Continuation
    private var nextOutboundID: UInt32
    private var streams: [UInt32: MuxStream] = [:]
    private var tornDown = false
    private var decoder = FrameDecoder()
    private var keepaliveTask: Task<Void, Never>?
    private var pendingPingNonce: Data?
    private var missedPings = 0
    private var inboundActivityCounter: UInt64 = 0

    public init(sink: @escaping @Sendable (Data) async throws -> Void, role: Role = .dialer) {
        self.init(sink: sink, role: role, sleeper: { try await Task.sleep(for: $0) })
    }

    internal init(
        sink: @escaping @Sendable (Data) async throws -> Void,
        role: Role = .dialer,
        sleeper: @escaping @Sendable (Duration) async throws -> Void
    ) {
        let incoming = AsyncStream<MuxStream>.makeStream()
        let keepalive = AsyncStream<Void>.makeStream()
        self.sink = sink
        self.role = role
        self.sleeper = sleeper
        self.incomingStreams = incoming.stream
        self.incomingContinuation = incoming.continuation
        self.keepaliveLostStream = keepalive.stream
        self.keepaliveLostContinuation = keepalive.continuation
        self.nextOutboundID = (role == .dialer) ? 1 : 2
    }

    public func openStream() async throws -> MuxStream {
        guard !tornDown else {
            throw MuxError.transportClosed
        }
        guard await activeStreamCount() < MuxConstants.maxConcurrentStreams else {
            throw MuxError.streamLimitExceeded
        }

        let id = nextOutboundID
        nextOutboundID &+= 2
        let stream = MuxStream(id: id, sink: sink)
        let frame = try encodeFrame(buildOpen(streamID: id))
        try await sink(frame)
        streams[id] = stream
        return stream
    }

    public func feedInbound(_ bytes: Data) async throws {
        guard !tornDown else {
            throw MuxError.transportClosed
        }

        decoder.feed(bytes)
        while let frame = try decoder.next() {
            try await dispatch(frame)
        }
    }

    public func startKeepalive(
        interval: Duration = .milliseconds(500),
        missedLimit: Int = 3
    ) {
        guard keepaliveTask == nil else {
            return
        }

        keepaliveTask = Task {
            await runKeepalive(interval: interval, missedLimit: missedLimit)
        }
    }

    public func tearDown(reason: TearDownReason) async {
        tornDown = true
        keepaliveTask?.cancel()
        keepaliveTask = nil
        keepaliveLostContinuation.finish()
        incomingContinuation.finish()
        let openStreams = streams.values
        streams.removeAll()
        for stream in openStreams {
            await stream.tearDown(reason: reason)
        }
    }

    private func dispatch(_ frame: Frame) async throws {
        inboundActivityCounter &+= 1

        let isOpen = frame.flags & FrameFlags.open.rawValue != 0
        let isData = frame.flags & FrameFlags.data.rawValue != 0
        let isClose = frame.flags & FrameFlags.close.rawValue != 0
        let isReset = frame.flags & FrameFlags.reset.rawValue != 0
        let isWindow = frame.flags & FrameFlags.window.rawValue != 0
        let isPing = frame.flags & FrameFlags.ping.rawValue != 0
        let isPong = frame.flags & FrameFlags.pong.rawValue != 0

        if frame.streamID == 0 {
            try await handleControlFrame(frame, isPing: isPing, isPong: isPong)
            return
        }

        let stream = streams[frame.streamID]

        if isPing || isPong {
            guard let stream else {
                throw MuxError.protocolError
            }
            try await isolateStream(stream, frame: frame, reason: .protocolError)
            return
        }

        if isOpen {
            try await handleInboundOpen(frame)
            return
        }

        guard let stream else {
            logger.debug(
                "ignoring frame for unknown stream id=\(frame.streamID, privacy: .public) flags=\(frame.flags, privacy: .public) length=\(frame.payload.count, privacy: .public)"
            )
            return
        }

        if isWindow {
            let credit: UInt32
            do {
                credit = try parseWindowCredit(from: frame.payload)
            } catch {
                try await isolateStream(stream, frame: frame, reason: .protocolError)
                return
            }
            await stream.grantSendCredit(credit)
        }
        if isData {
            let outcome = try await stream.deliverInboundData(frame.payload)
            if outcome == .receiveWindowExceeded {
                try await isolateStream(stream, frame: frame, reason: .flowControlError)
                return
            }
        }
        if isClose {
            await stream.deliverInboundClose()
        }
        if isReset {
            let reason = parseResetReason(from: frame.payload)
            await stream.deliverInboundReset(reason: reason)
        }
    }

    private func isolateStream(_ stream: MuxStream, frame: Frame, reason: ResetReason) async throws {
        logger.warning(
            "isolating stream violation id=\(frame.streamID, privacy: .public) flags=\(frame.flags, privacy: .public) length=\(frame.payload.count, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )

        guard await stream.markResetLocal() else {
            return
        }

        try await sink(try encodeFrame(buildReset(streamID: frame.streamID, reason: reason)))
    }

    private func handleInboundOpen(_ frame: Frame) async throws {
        let isOdd = frame.streamID % 2 == 1
        let parityRejected = (role == .dialer && isOdd) || (role == .listener && !isOdd)
        if parityRejected {
            logger.debug("inbound OPEN parity rejected id=\(frame.streamID, privacy: .public)")
            let reset = try encodeFrame(buildReset(streamID: frame.streamID, reason: .protocolError))
            try await sink(reset)
            return
        }

        guard role == .listener else {
            logger.debug("ignoring inbound OPEN id=\(frame.streamID, privacy: .public)")
            return
        }

        guard await activeStreamCount() < MuxConstants.maxConcurrentStreams else {
            let reset = try encodeFrame(buildReset(streamID: frame.streamID, reason: .streamLimitExceeded))
            try await sink(reset)
            return
        }

        let stream = MuxStream(id: frame.streamID, sink: sink)
        streams[frame.streamID] = stream
        incomingContinuation.yield(stream)
    }

    private func handleControlFrame(_ frame: Frame, isPing: Bool, isPong: Bool) async throws {
        switch (isPing, isPong) {
        case (true, false):
            let nonce = try parseControlNonce(from: frame.payload)
            try await sink(try encodeFrame(buildPong(nonce: nonce)))
        case (false, true):
            let nonce = try parseControlNonce(from: frame.payload)
            if nonce == pendingPingNonce {
                pendingPingNonce = nil
                missedPings = 0
            }
        default:
            throw FramingError.unknownControlFrame
        }
    }

    private func runKeepalive(interval: Duration, missedLimit: Int) async {
        while !Task.isCancelled {
            do {
                try await sleeper(interval)
                try await sendKeepalivePing(missedLimit: missedLimit)
            } catch {
                await tearDown(reason: .transportFailure)
                return
            }
        }
    }

    private func sendKeepalivePing(missedLimit: Int) async throws {
        guard !tornDown else {
            throw MuxError.transportClosed
        }

        if pendingPingNonce != nil {
            missedPings += 1
            if missedPings >= missedLimit {
                logger.debug("mux keepalive lost missed_pings=\(self.missedPings, privacy: .public)")
                keepaliveLostContinuation.yield(())
                keepaliveTask?.cancel()
                keepaliveTask = nil
                return
            }
        }

        var nonce = Data(count: 8)
        nonce.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, 8, buffer.baseAddress!)
        }
        pendingPingNonce = nonce
        try await sink(try encodeFrame(buildPing(nonce: nonce)))
    }

    private func activeStreamCount() async -> Int {
        var count = 0
        for stream in streams.values {
            let state = await stream.state
            if state == .open || state == .halfClosedRemote {
                count += 1
            }
        }
        return count
    }

    public func inboundActivitySnapshot() -> UInt64 {
        inboundActivityCounter
    }
}
