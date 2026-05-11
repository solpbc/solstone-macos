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
        let (mux, recorder) = makeMultiplexer()

        await mux.startKeepalive(interval: .milliseconds(20), missedLimit: 10)
        try await Task.sleep(for: .milliseconds(75))
        await mux.tearDown(reason: .normalShutdown)

        let frames = try await recorder.frames()
        #expect(frames.filter { $0.streamID == 0 && $0.flags == FrameFlags.ping.rawValue }.count >= 2)
    }

    @Test("matching PONG resets missed ping count")
    func matchingPongResetsMissedPingCount() async throws {
        let (mux, recorder) = makeMultiplexer()
        let lost = mux.keepaliveLost

        await mux.startKeepalive(interval: .milliseconds(20), missedLimit: 3)
        try await Task.sleep(for: .milliseconds(25))
        let firstPing = try #require(try await recorder.frames().first { $0.flags == FrameFlags.ping.rawValue })
        try await mux.feedInbound(try encodeFrame(buildPong(nonce: firstPing.payload)))
        try await Task.sleep(for: .milliseconds(35))
        await mux.tearDown(reason: .normalShutdown)

        #expect(try await firstKeepaliveLost(from: lost, timeout: .milliseconds(20)) == false)
    }

    @Test("three missed pongs triggers keepalive lost")
    func missedPongsTriggerKeepaliveLost() async throws {
        let (mux, _) = makeMultiplexer()
        let lost = mux.keepaliveLost

        await mux.startKeepalive(interval: .milliseconds(10), missedLimit: 3)

        #expect(try await firstKeepaliveLost(from: lost, timeout: .milliseconds(120)))
        await mux.tearDown(reason: .transportFailure)
    }

    private func makeMultiplexer() -> (Multiplexer, SinkRecorder) {
        let recorder = SinkRecorder()
        let mux = Multiplexer { data in
            await recorder.record(data)
        }
        return (mux, recorder)
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

    private func firstKeepaliveLost(from stream: AsyncStream<Void>, timeout: Duration) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
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
