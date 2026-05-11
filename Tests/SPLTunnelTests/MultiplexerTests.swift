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

    private func makeMultiplexer() -> (Multiplexer, SinkRecorder) {
        let recorder = SinkRecorder()
        let mux = Multiplexer { data in
            await recorder.record(data)
        }
        return (mux, recorder)
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
