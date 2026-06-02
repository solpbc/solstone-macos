// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SPLTunnel

private actor SinkRecorder {
    private var chunks: [Data] = []

    func record(_ data: Data) {
        chunks.append(data)
    }

    func reset() {
        chunks.removeAll()
    }

    func frames() throws -> [Frame] {
        var decoder = FrameDecoder()
        var frames: [Frame] = []
        for chunk in chunks {
            decoder.feed(chunk)
            while let frame = try decoder.next() {
                frames.append(frame)
            }
        }
        return frames
    }
}

private actor KeepaliveTickGate {
    private var parkedTick: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    // Injected as the Multiplexer's keepalive sleeper. Parks each loop iteration
    // until the test calls release(). The Duration is ignored — the gate controls timing.
    func tick() async {
        await withCheckedContinuation { continuation in
            parkedTick = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    // Blocks until the keepalive loop is parked at a tick. Returning guarantees the
    // previous iteration (and its PING write) has completed.
    func waitForTick() async {
        if parkedTick != nil { return }
        await withCheckedContinuation { continuation in arrival = continuation }
    }

    // Releases exactly one parked tick so a single keepalive iteration runs.
    func release() {
        guard let continuation = parkedTick else { return }
        parkedTick = nil
        continuation.resume()
    }
}

private actor CompletionFlag {
    private var complete = false

    func setComplete() {
        complete = true
    }

    var isComplete: Bool {
        complete
    }
}

@Suite("Multiplexer")
struct MultiplexerTests {
    @Test("outbound IDs allocate 1,3,5 monotonically")
    func outboundIDsAllocateOddMonotonically() async throws {
        let (mux, _) = makeMultiplexer()

        let first = try await mux.openStream()
        let second = try await mux.openStream()
        let third = try await mux.openStream()

        #expect(await [first.id, second.id, third.id] == [1, 3, 5])
    }

    @Test("257th open throws streamLimitExceeded; close frees slot")
    func streamLimitAndCloseFreesSlot() async throws {
        let (mux, _) = makeMultiplexer()
        var streams: [MuxStream] = []

        for _ in 0..<MuxConstants.maxConcurrentStreams {
            streams.append(try await mux.openStream())
        }

        await expectAsyncThrows(.streamLimitExceeded) {
            _ = try await mux.openStream()
        }

        try await streams[0].close()
        let next = try await mux.openStream()
        #expect(await next.id == 513)
    }

    @Test("inbound odd OPEN emits RESET(protocolError) via sink")
    func inboundOddOpenEmitsProtocolReset() async throws {
        let (mux, recorder) = makeMultiplexer()

        try await mux.feedInbound(try encodeFrame(buildOpen(streamID: 11)))

        let frames = try await recorder.frames()
        let reset = try #require(frames.first)
        #expect(reset.streamID == 11)
        #expect(reset.flags == FrameFlags.reset.rawValue)
        #expect(try parseResetReason(from: reset.payload) == .protocolError)
    }

    @Test("credit suspend/resume - 800 KiB + 300 KiB with 200 KiB WINDOW")
    func creditSuspendResume() async throws {
        let (mux, _) = makeMultiplexer()
        let stream = try await mux.openStream()
        let complete = CompletionFlag()

        let writeTask = Task {
            try await stream.write(Data(repeating: 0, count: 800 * 1024))
            try await stream.write(Data(repeating: 0, count: 300 * 1024))
            await complete.setComplete()
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await !complete.isComplete)

        try await mux.feedInbound(try encodeFrame(buildWindow(streamID: 1, credit: 200 * 1024)))
        try await writeTask.value
        #expect(await complete.isComplete)
    }

    @Test("write(200 KiB) emits >= 3 DATA frames each <= 64 KiB")
    func writeChunksLargePayload() async throws {
        let (mux, recorder) = makeMultiplexer()
        let stream = try await mux.openStream()
        await recorder.reset()

        try await stream.write(Data(repeating: 0, count: 200 * 1024))

        let frames = try await recorder.frames()
        #expect(frames.count >= 3)
        #expect(frames.allSatisfy { $0.flags == FrameFlags.data.rawValue })
        #expect(frames.allSatisfy { $0.payload.count <= MuxConstants.recommendedChunk })
    }

    @Test("inbound 70 KiB DATA - reader drains - outbound WINDOW emitted")
    func inboundDataEmitsWindowGrant() async throws {
        let (mux, recorder) = makeMultiplexer()
        let stream = try await mux.openStream()
        await recorder.reset()

        try await mux.feedInbound(try encodeFrame(buildData(
            streamID: 1,
            payload: Data(repeating: 0, count: 70 * 1024)
        )))

        var iterator = await stream.inbound.makeAsyncIterator()
        let payload = try await iterator.next()
        #expect(payload?.count == 70 * 1024)

        let frames = try await recorder.frames()
        let window = try #require(frames.first { $0.flags == FrameFlags.window.rawValue })
        #expect(window.streamID == 1)
        #expect(try parseWindowCredit(from: window.payload) == 70 * 1024)
    }

    @Test("half-close round-trip - state .closed, inbound finishes")
    func halfCloseRoundTrip() async throws {
        let (mux, _) = makeMultiplexer()
        let stream = try await mux.openStream()

        try await stream.close()
        try await mux.feedInbound(try encodeFrame(buildClose(streamID: 1)))

        #expect(await stream.state == .closed)
        var iterator = await stream.inbound.makeAsyncIterator()
        let next = try await iterator.next()
        #expect(next == nil)
    }

    @Test("inbound RESET throws on inbound and bars further writes")
    func inboundResetThrowsAndBarsWrites() async throws {
        let (mux, _) = makeMultiplexer()
        let stream = try await mux.openStream()

        try await mux.feedInbound(try encodeFrame(buildReset(streamID: 1, reason: .protocolError)))

        var iterator = await stream.inbound.makeAsyncIterator()
        await expectAsyncThrows(.transportClosed) {
            _ = try await iterator.next()
        }
        await expectAsyncThrows(.writeAfterClose) {
            try await stream.write(Data([0x01]))
        }
    }

    @Test("tearDown(.transportFailure) - open inbound throws; openStream throws transportClosed")
    func tearDownThrowsOpenInboundAndBlocksOpenStream() async throws {
        let (mux, _) = makeMultiplexer()
        let streams = [
            try await mux.openStream(),
            try await mux.openStream(),
            try await mux.openStream()
        ]

        await mux.tearDown(reason: .transportFailure)

        for stream in streams {
            var iterator = await stream.inbound.makeAsyncIterator()
            await expectAsyncThrows(.transportClosed) {
                _ = try await iterator.next()
            }
        }
        await expectAsyncThrows(.transportClosed) {
            _ = try await mux.openStream()
        }
    }

    @Test("listener outbound IDs allocate 2,4,6 monotonically")
    func listenerOutboundIDsAllocateEvenMonotonically() async throws {
        let recorder = SinkRecorder()
        let mux = Multiplexer(sink: { data in
            await recorder.record(data)
        }, role: .listener)

        let first = try await mux.openStream()
        let second = try await mux.openStream()
        let third = try await mux.openStream()

        #expect(await [first.id, second.id, third.id] == [2, 4, 6])
    }

    @Test("listener inbound odd OPEN is accepted and yielded")
    func listenerInboundOddOpenIsAcceptedAndYielded() async throws {
        let recorder = SinkRecorder()
        let mux = Multiplexer(sink: { data in
            await recorder.record(data)
        }, role: .listener)
        let incoming = mux.incomingStreams

        try await mux.feedInbound(try encodeFrame(buildOpen(streamID: 1)))

        let stream = try await firstIncomingStream(from: incoming)
        #expect(await stream?.id == 1)
    }

    @Test("listener inbound even OPEN emits RESET(protocolError) via sink")
    func listenerInboundEvenOpenEmitsProtocolReset() async throws {
        let recorder = SinkRecorder()
        let mux = Multiplexer(sink: { data in
            await recorder.record(data)
        }, role: .listener)

        try await mux.feedInbound(try encodeFrame(buildOpen(streamID: 2)))

        let frames = try await recorder.frames()
        let reset = try #require(frames.first)
        #expect(reset.streamID == 2)
        #expect(reset.flags == FrameFlags.reset.rawValue)
        #expect(try parseResetReason(from: reset.payload) == .protocolError)
    }

    @Test("dialer incomingStreams finishes on tearDown")
    func dialerIncomingStreamsFinishOnTearDown() async throws {
        let (mux, _) = makeMultiplexer()
        let incoming = mux.incomingStreams

        await mux.tearDown(reason: .normalShutdown)

        let stream = try await firstIncomingStream(from: incoming)
        #expect(stream == nil)
    }

    @Test("control PING emits matching PONG on stream 0")
    func controlPingEmitsPong() async throws {
        let (mux, recorder) = makeMultiplexer()
        let nonce = Data([1, 2, 3, 4, 5, 6, 7, 8])

        try await mux.feedInbound(try encodeFrame(buildPing(nonce: nonce)))

        let frames = try await recorder.frames()
        #expect(frames == [try buildPong(nonce: nonce)])
    }

    @Test("keepalive sends pings at configured cadence")
    func keepaliveSendsPingsAtCadence() async throws {
        let (mux, recorder, gate) = makeGatedMultiplexer()

        // Interval is ignored; the gate drives ticks deterministically.
        await mux.startKeepalive(missedLimit: 10)

        await gate.waitForTick()   // parked before ping #1
        await gate.release()       // -> ping #1
        await gate.waitForTick()   // parked before ping #2 (ping #1 now written)
        await gate.release()       // -> ping #2
        await gate.waitForTick()   // parked before ping #3 (ping #2 now written)

        await mux.tearDown(reason: .normalShutdown)
        await gate.release()       // flush the parked iteration so it observes tornDown and exits

        let frames = try await recorder.frames()
        #expect(frames.filter { $0.streamID == 0 && $0.flags == FrameFlags.ping.rawValue }.count >= 2)
    }

    @Test("matching PONG resets missed ping count")
    func matchingPongResetsMissedPingCount() async throws {
        let (mux, recorder, gate) = makeGatedMultiplexer()
        let lost = mux.keepaliveLost

        // Interval is ignored; the gate drives ticks deterministically.
        await mux.startKeepalive(missedLimit: 3)

        await gate.waitForTick()   // parked before ping #1
        await gate.release()       // -> ping #1, pendingPingNonce set
        await gate.waitForTick()   // ping #1 written

        let firstPing = try #require(
            try await recorder.frames().first { $0.streamID == 0 && $0.flags == FrameFlags.ping.rawValue }
        )
        try await mux.feedInbound(try encodeFrame(buildPong(nonce: firstPing.payload)))  // resets missedPings, clears nonce

        await gate.release()       // -> ping #2 (pendingPingNonce was cleared, so a fresh ping is sent)
        await gate.waitForTick()   // ping #2 written; loop still alive

        await mux.tearDown(reason: .normalShutdown)   // finishes the keepaliveLost stream
        await gate.release()                          // flush parked iteration -> observes tornDown and exits

        var lostIterator = lost.makeAsyncIterator()
        #expect(await lostIterator.next() == nil)      // no keepaliveLost was emitted before finish

        let pings = try await recorder.frames().filter { $0.streamID == 0 && $0.flags == FrameFlags.ping.rawValue }
        #expect(pings.count == 2)                       // a new ping was sent after the matching pong
    }

    @Test("three missed pongs triggers keepalive lost")
    func missedPongsTriggerKeepaliveLost() async throws {
        let (mux, _, gate) = makeGatedMultiplexer()
        let lost = mux.keepaliveLost

        // Interval is ignored; the gate drives ticks deterministically.
        await mux.startKeepalive(missedLimit: 3)

        // Drive four iterations with no PONG. Iterations 1-3 send pings (missed 0,1,2);
        // the 4th reaches missedPings == 3 and yields keepaliveLost, then the loop exits.
        for _ in 0..<4 {
            await gate.waitForTick()
            await gate.release()
        }

        var lostIterator = lost.makeAsyncIterator()
        #expect(await lostIterator.next() != nil)   // keepaliveLost fired; blocks only until the yield, no wall-clock wait

        await mux.tearDown(reason: .transportFailure)
    }

    private func makeMultiplexer() -> (Multiplexer, SinkRecorder) {
        let recorder = SinkRecorder()
        let mux = Multiplexer { data in
            await recorder.record(data)
        }
        return (mux, recorder)
    }

    private func makeGatedMultiplexer() -> (Multiplexer, SinkRecorder, KeepaliveTickGate) {
        let recorder = SinkRecorder()
        let gate = KeepaliveTickGate()
        let mux = Multiplexer(
            sink: { data in await recorder.record(data) },
            sleeper: { _ in await gate.tick() }
        )
        return (mux, recorder, gate)
    }

    private func firstIncomingStream(from incoming: AsyncStream<MuxStream>) async throws -> MuxStream? {
        try await withThrowingTaskGroup(of: MuxStream?.self) { group in
            group.addTask {
                var iterator = incoming.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw MuxError.transportClosed
            }
            let stream = try await group.next()!
            group.cancelAll()
            return stream
        }
    }
}

private func expectAsyncThrows(
    _ expected: MuxError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected)")
    } catch let error as MuxError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected), got \(error)")
    }
}
