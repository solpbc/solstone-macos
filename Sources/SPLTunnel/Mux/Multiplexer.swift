// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let logger = Logger(subsystem: "app.solstone.observer.spl", category: "mux")

public enum MuxError: Error, Equatable {
    case streamLimitExceeded
    case parityViolation
    case unknownStream
    case flowControlError
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

public actor Multiplexer {
    private let sink: @Sendable (Data) async throws -> Void
    private var nextOutboundID: UInt32 = 1
    private var streams: [UInt32: MuxStream] = [:]
    private var tornDown = false
    private var decoder = FrameDecoder()

    public init(sink: @escaping @Sendable (Data) async throws -> Void) {
        self.sink = sink
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

    public func tearDown(reason: TearDownReason) async {
        tornDown = true
        let openStreams = streams.values
        streams.removeAll()
        for stream in openStreams {
            await stream.tearDown(reason: reason)
        }
    }

    private func dispatch(_ frame: Frame) async throws {
        let isOpen = frame.flags & FrameFlags.open.rawValue != 0
        let isData = frame.flags & FrameFlags.data.rawValue != 0
        let isClose = frame.flags & FrameFlags.close.rawValue != 0
        let isReset = frame.flags & FrameFlags.reset.rawValue != 0
        let isWindow = frame.flags & FrameFlags.window.rawValue != 0

        if isOpen {
            try await handleInboundOpen(frame)
            return
        }

        guard let stream = streams[frame.streamID] else {
            logger.debug(
                "ignoring frame for unknown stream id=\(frame.streamID, privacy: .public) flags=\(frame.flags, privacy: .public) length=\(frame.payload.count, privacy: .public)"
            )
            return
        }

        if isWindow {
            let credit = try parseWindowCredit(from: frame.payload)
            await stream.grantSendCredit(credit)
        }
        if isData {
            try await stream.deliverInboundData(frame.payload)
        }
        if isClose {
            await stream.deliverInboundClose()
        }
        if isReset {
            let reason = try parseResetReason(from: frame.payload)
            await stream.deliverInboundReset(reason: reason)
        }
    }

    private func handleInboundOpen(_ frame: Frame) async throws {
        if frame.streamID % 2 == 1 {
            logger.debug("parity violation on inbound OPEN id=\(frame.streamID, privacy: .public)")
            let reset = try encodeFrame(buildReset(streamID: frame.streamID, reason: .protocolError))
            try await sink(reset)
            return
        }

        logger.debug("ignoring inbound even OPEN id=\(frame.streamID, privacy: .public)")
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
}
