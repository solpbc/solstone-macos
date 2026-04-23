// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("HeartbeatService")
struct HeartbeatServiceTests {
    actor HeartbeatRecorder {
        private(set) var calls: [(url: String, key: String, paused: Bool)] = []

        func record(url: String, key: String, paused: Bool) {
            calls.append((url: url, key: key, paused: paused))
        }

        func callCount() -> Int {
            calls.count
        }

        func recordedCalls() -> [(url: String, key: String, paused: Bool)] {
            calls
        }
    }

    @MainActor
    final class PauseStateBox {
        var isPaused = false
    }

    @Test func configureStartsLoopAndStopPreventsFurtherPosts() async {
        let recorder = HeartbeatRecorder()
        let service = HeartbeatService(
            intervalSeconds: 0.05,
            isPaused: { false },
            postHeartbeat: { url, key, paused in
                await recorder.record(url: url, key: key, paused: paused)
            }
        )

        await service.configure(serverURL: "http://test.invalid", serverKey: "k1")
        var runningCount = await recorder.callCount()
        for _ in 0..<20 where runningCount < 2 {
            try? await Task.sleep(for: .seconds(0.05))
            runningCount = await recorder.callCount()
        }
        #expect(runningCount >= 2)

        await service.stop()
        try? await Task.sleep(for: .seconds(0.2))
        let settledCount = await recorder.callCount()
        try? await Task.sleep(for: .seconds(0.2))

        let stoppedCount = await recorder.callCount()
        #expect(stoppedCount == settledCount)

        let calls = await recorder.recordedCalls()
        #expect(calls.allSatisfy { $0.url == "http://test.invalid" })
        #expect(calls.allSatisfy { $0.key == "k1" })
        #expect(calls.allSatisfy { $0.paused == false })
    }

    @Test @MainActor func heartbeatReadsLatestPauseStateOnEachTick() async {
        let recorder = HeartbeatRecorder()
        let pauseState = PauseStateBox()
        let service = HeartbeatService(
            intervalSeconds: 0.05,
            isPaused: { [pauseState] in
                pauseState.isPaused
            },
            postHeartbeat: { url, key, paused in
                await recorder.record(url: url, key: key, paused: paused)
            }
        )

        await service.configure(serverURL: "http://test.invalid", serverKey: "k1")
        try? await Task.sleep(for: .seconds(0.1))
        pauseState.isPaused = true
        try? await Task.sleep(for: .seconds(0.1))
        pauseState.isPaused = false
        try? await Task.sleep(for: .seconds(0.1))
        await service.stop()

        let calls = await recorder.recordedCalls()
        #expect(calls.contains { $0.paused })
        #expect(calls.contains { !$0.paused })
    }
}
