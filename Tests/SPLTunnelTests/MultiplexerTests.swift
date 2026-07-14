// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SPLTunnel

private func decodeFrames(in data: Data) throws -> [Frame] {
    var decoder = FrameDecoder()
    var frames: [Frame] = []
    decoder.feed(data)
    while let frame = try decoder.next() {
        frames.append(frame)
    }
    return frames
}

private actor SinkRecorder {
    private var chunks: [Data] = []

    func record(_ data: Data) {
        chunks.append(data)
    }

    func reset() {
        chunks.removeAll()
    }

    func frames() throws -> [Frame] {
        var frames: [Frame] = []
        for chunk in chunks {
            frames.append(contentsOf: try decodeFrames(in: chunk))
        }
        return frames
    }
}

private enum ThrowingResetSinkError: Error, Equatable {
    case resetWrite
}

private enum WindowGrantSinkError: Error, Equatable {
    case boom
}

private actor ThrowingResetSink {
    func recordOrThrow(_ data: Data) throws {
        if try decodeFrames(in: data).contains(where: { $0.flags == FrameFlags.reset.rawValue }) {
            throw ThrowingResetSinkError.resetWrite
        }
    }
}

private actor WindowGrantThrowingSink {
    private var frames: [Frame] = []

    func recordOrThrow(_ data: Data) throws {
        let decoded = try decodeFrames(in: data)
        frames.append(contentsOf: decoded)
        if decoded.contains(where: { $0.flags == FrameFlags.window.rawValue }) {
            throw WindowGrantSinkError.boom
        }
    }

    func recordedFrames() -> [Frame] {
        frames
    }
}

private actor KeepaliveTickGate {
    private var parkedTick: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    // Injected as the Multiplexer's keepalive sleeper. Parks each loop iteration
    // until the test calls release(). The Duration is ignored; the gate controls timing.
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
        #expect(parseResetReason(from: reset.payload) == .protocolError)
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

    @Test("inbound RESET with unknown reason does not tear down mux")
    func inboundResetWithUnknownReasonDoesNotTearDownMux() async throws {
        let (mux, recorder) = makeMultiplexer()
        _ = try await mux.openStream()
        let sibling = try await mux.openStream()

        try await mux.feedInbound(Data([
            0x00, 0x00, 0x00, 0x01,
            FrameFlags.reset.rawValue,
            0x00, 0x00, 0x01,
            0x42
        ]))

        await recorder.reset()
        try await sibling.write(Data([0xa5]))
        let outboundFrames = try await recorder.frames()
        let outboundData = try #require(outboundFrames.first { $0.flags == FrameFlags.data.rawValue })
        #expect(outboundData.streamID == 3)
        #expect(outboundData.payload == Data([0xa5]))

        try await mux.feedInbound(try encodeFrame(buildData(streamID: 3, payload: Data([0x5a]))))
        var iterator = await sibling.inbound.makeAsyncIterator()
        let inbound = try await iterator.next()
        #expect(inbound == Data([0x5a]))

        let next = try await mux.openStream()
        #expect(await next.id == 5)
    }

    @Test("malformed WINDOW resets only that stream and mux survives")
    func malformedWindowResetsOnlyThatStreamAndMuxSurvives() async throws {
        let (mux, recorder) = makeMultiplexer()
        let isolated = try await mux.openStream()
        let sibling = try await mux.openStream()
        await recorder.reset()

        try await mux.feedInbound(try encodeFrame(Frame(
            streamID: await isolated.id,
            flags: FrameFlags.window.rawValue,
            payload: Data([0x00, 0x00, 0x00])
        )))

        try await assertIsolatedAndMuxSurvives(
            mux: mux,
            recorder: recorder,
            isolated: isolated,
            sibling: sibling,
            expectedReason: .protocolError
        )
    }

    @Test("repeated malformed WINDOW after isolation emits one RESET")
    func repeatedMalformedWindowAfterIsolationEmitsOneReset() async throws {
        let (mux, recorder) = makeMultiplexer()
        let isolated = try await mux.openStream()
        let sibling = try await mux.openStream()
        await recorder.reset()

        try await mux.feedInbound(try encodeFrame(Frame(
            streamID: await isolated.id,
            flags: FrameFlags.window.rawValue,
            payload: Data([0x00, 0x00, 0x00])
        )))
        try await mux.feedInbound(try encodeFrame(Frame(
            streamID: await isolated.id,
            flags: FrameFlags.window.rawValue,
            payload: Data([0x00, 0x00, 0x00, 0x00, 0x00])
        )))

        try await assertIsolatedAndMuxSurvives(
            mux: mux,
            recorder: recorder,
            isolated: isolated,
            sibling: sibling,
            expectedReason: .protocolError
        )
    }

    @Test("over-window DATA resets only that stream and mux survives")
    func overWindowDataResetsOnlyThatStreamAndMuxSurvives() async throws {
        let (mux, recorder) = makeMultiplexer()
        let isolated = try await mux.openStream()
        let sibling = try await mux.openStream()
        await recorder.reset()

        try await mux.feedInbound(try encodeFrame(buildData(
            streamID: await isolated.id,
            payload: Data(repeating: 0, count: Int(MuxConstants.initialCredit) + 1)
        )))

        try await assertIsolatedAndMuxSurvives(
            mux: mux,
            recorder: recorder,
            isolated: isolated,
            sibling: sibling,
            expectedReason: .flowControlError
        )
    }

    @Test("nonzero PING and PONG reset only that stream and mux survives")
    func nonzeroPingAndPongResetOnlyThatStreamAndMuxSurvive() async throws {
        for flag in [FrameFlags.ping.rawValue, FrameFlags.pong.rawValue] {
            let (mux, recorder) = makeMultiplexer()
            let isolated = try await mux.openStream()
            let sibling = try await mux.openStream()
            await recorder.reset()

            try await mux.feedInbound(try encodeFrame(Frame(
                streamID: await isolated.id,
                flags: flag,
                payload: Data([1, 2, 3, 4, 5, 6, 7, 8])
            )))

            try await assertIsolatedAndMuxSurvives(
                mux: mux,
                recorder: recorder,
                isolated: isolated,
                sibling: sibling,
                expectedReason: .protocolError
            )
        }
    }

    @Test("isolation RESET sink failure propagates")
    func isolationResetSinkFailurePropagates() async throws {
        let throwingSink = ThrowingResetSink()
        let mux = Multiplexer { data in
            try await throwingSink.recordOrThrow(data)
        }
        let isolated = try await mux.openStream()

        do {
            try await mux.feedInbound(try encodeFrame(Frame(
                streamID: await isolated.id,
                flags: FrameFlags.window.rawValue,
                payload: Data([0x00, 0x00, 0x00])
            )))
            Issue.record("Expected reset sink failure")
        } catch ThrowingResetSinkError.resetWrite {
        } catch {
            Issue.record("Expected reset sink failure, got \(error)")
        }
    }

    @Test("WINDOW grant sink failure remains transport-fatal")
    func windowGrantSinkFailureRemainsTransportFatal() async throws {
        let throwingSink = WindowGrantThrowingSink()
        let mux = Multiplexer { data in
            try await throwingSink.recordOrThrow(data)
        }
        let stream = try await mux.openStream()
        let streamID = await stream.id

        do {
            try await mux.feedInbound(try encodeFrame(buildData(
                streamID: streamID,
                payload: Data(repeating: 0, count: MuxConstants.windowGrantThreshold)
            )))
            Issue.record("Expected WINDOW grant sink failure")
        } catch WindowGrantSinkError.boom {
        } catch {
            Issue.record("Expected WINDOW grant sink failure, got \(error)")
        }

        let frames = await throwingSink.recordedFrames()
        #expect(frames.contains { $0.streamID == streamID && $0.flags == FrameFlags.window.rawValue })
        #expect(!frames.contains { $0.streamID == streamID && $0.flags == FrameFlags.reset.rawValue })
    }

    @Test("non-isolated protocol errors remain fatal")
    func nonIsolatedProtocolErrorsRemainFatal() async throws {
        let (unknownMux, unknownRecorder) = makeMultiplexer()
        await expectAsyncThrows(.protocolError) {
            try await unknownMux.feedInbound(try encodeFrame(Frame(
                streamID: 1,
                flags: FrameFlags.ping.rawValue,
                payload: Data([1, 2, 3, 4, 5, 6, 7, 8])
            )))
        }
        try await expectNoResetFrames(in: unknownRecorder)

        let (controlMux, controlRecorder) = makeMultiplexer()
        await expectAsyncThrows(FramingError.lengthMismatch) {
            try await controlMux.feedInbound(try encodeFrame(Frame(
                streamID: 0,
                flags: FrameFlags.ping.rawValue,
                payload: Data([0x01])
            )))
        }
        try await expectNoResetFrames(in: controlRecorder)
    }

    @Test("decoder validation errors remain fatal before dispatch")
    func decoderValidationErrorsRemainFatalBeforeDispatch() async throws {
        let (mux, recorder) = makeMultiplexer()

        await expectAsyncThrows(FramingError.reservedBitsSet) {
            try await mux.feedInbound(Data([
                0x00, 0x00, 0x00, 0x01,
                0x80,
                0x00, 0x00, 0x00
            ]))
        }

        try await expectNoResetFrames(in: recorder)
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
        #expect(parseResetReason(from: reset.payload) == .protocolError)
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

    @Test("inbound activity counter increments for control and stream frames")
    func inboundActivityCounterIncrementsForDecodedFrames() async throws {
        let (mux, _) = makeMultiplexer()

        #expect(await mux.inboundActivitySnapshot() == 0)

        try await mux.feedInbound(try encodeFrame(buildPing(nonce: Data([1, 2, 3, 4, 5, 6, 7, 8]))))
        #expect(await mux.inboundActivitySnapshot() == 1)

        try await mux.feedInbound(try encodeFrame(buildData(streamID: 1, payload: Data([0x01]))))
        #expect(await mux.inboundActivitySnapshot() == 2)
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

    private func assertIsolatedAndMuxSurvives(
        mux: Multiplexer,
        recorder: SinkRecorder,
        isolated: MuxStream,
        sibling: MuxStream,
        expectedReason: ResetReason
    ) async throws {
        let isolatedID = await isolated.id
        let siblingID = await sibling.id
        let frames = try await recorder.frames()
        let resets = frames.filter { $0.flags == FrameFlags.reset.rawValue }
        #expect(resets.count == 1)

        let reset = try #require(resets.first)
        #expect(reset.streamID == isolatedID)
        #expect(parseResetReason(from: reset.payload) == expectedReason)

        var isolatedIterator = await isolated.inbound.makeAsyncIterator()
        await expectAsyncThrows(.transportClosed) {
            _ = try await isolatedIterator.next()
        }
        await expectAsyncThrows(.writeAfterClose) {
            try await isolated.write(Data([0x01]))
        }

        await recorder.reset()
        try await sibling.write(Data([0xa5]))
        let outboundFrames = try await recorder.frames()
        let outboundData = try #require(outboundFrames.first { $0.flags == FrameFlags.data.rawValue })
        #expect(outboundData.streamID == siblingID)
        #expect(outboundData.payload == Data([0xa5]))

        try await mux.feedInbound(try encodeFrame(buildData(streamID: siblingID, payload: Data([0x5a]))))
        var siblingIterator = await sibling.inbound.makeAsyncIterator()
        let inbound = try await siblingIterator.next()
        #expect(inbound == Data([0x5a]))

        let next = try await mux.openStream()
        #expect(await next.id == 5)
    }

    private func expectNoResetFrames(in recorder: SinkRecorder) async throws {
        let frames = try await recorder.frames()
        #expect(!frames.contains { $0.flags == FrameFlags.reset.rawValue })
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

private func expectAsyncThrows(
    _ expected: FramingError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected)")
    } catch let error as FramingError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected), got \(error)")
    }
}
