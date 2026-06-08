// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("HeartbeatService")
struct HeartbeatServiceTests {
    actor HeartbeatRecorder {
        private(set) var calls: [(url: String, key: String, paused: Bool)] = []
        private var postWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var releasedPosts: Set<Int> = []
        private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
        private var exitedPosts: Set<Int> = []
        private var exitWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

        func recordAndPark(url: String, key: String, paused: Bool) async {
            calls.append((url: url, key: key, paused: paused))
            let ordinal = calls.count
            resumePostWaiters()
            await waitForRelease(ordinal)
            markPostExited(ordinal)
        }

        func callCount() -> Int {
            calls.count
        }

        func recordedCalls() -> [(url: String, key: String, paused: Bool)] {
            calls
        }

        func waitForPost(_ target: Int) async {
            await withCheckedContinuation { continuation in
                if calls.count >= target {
                    continuation.resume()
                } else {
                    postWaiters.append((target: target, continuation: continuation))
                }
            }
        }

        func releasePost(_ ordinal: Int) {
            releasedPosts.insert(ordinal)
            let waiters = releaseWaiters.removeValue(forKey: ordinal) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }

        func releaseAndWaitForPostExit(_ ordinal: Int) async {
            releasePost(ordinal)
            await waitForPostExit(ordinal)
        }

        private func waitForRelease(_ ordinal: Int) async {
            await withCheckedContinuation { continuation in
                if releasedPosts.contains(ordinal) {
                    continuation.resume()
                } else {
                    releaseWaiters[ordinal, default: []].append(continuation)
                }
            }
        }

        private func waitForPostExit(_ ordinal: Int) async {
            await withCheckedContinuation { continuation in
                if exitedPosts.contains(ordinal) {
                    continuation.resume()
                } else {
                    exitWaiters[ordinal, default: []].append(continuation)
                }
            }
        }

        private func markPostExited(_ ordinal: Int) {
            exitedPosts.insert(ordinal)
            let waiters = exitWaiters.removeValue(forKey: ordinal) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }

        private func resumePostWaiters() {
            var ready: [CheckedContinuation<Void, Never>] = []
            var pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in postWaiters {
                if calls.count >= waiter.target {
                    ready.append(waiter.continuation)
                } else {
                    pending.append(waiter)
                }
            }
            postWaiters = pending
            for waiter in ready {
                waiter.resume()
            }
        }
    }

    @MainActor
    final class PauseStateBox {
        var isPaused = false
    }

    @Test func configureStartsLoopAndStopPreventsFurtherPosts() async {
        let recorder = HeartbeatRecorder()
        let service = HeartbeatService(
            intervalSeconds: 0,
            isPaused: { false },
            postHeartbeat: { url, key, paused in
                await recorder.recordAndPark(url: url, key: key, paused: paused)
            }
        )

        await service.configure(serverURL: "http://test.invalid", serverKey: "k1")
        await recorder.waitForPost(1)
        await recorder.releasePost(1)
        await recorder.waitForPost(2)
        let settledCount = await recorder.callCount()
        await service.stop()
        await recorder.releaseAndWaitForPostExit(2)

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
            intervalSeconds: 0,
            isPaused: { [pauseState] in
                pauseState.isPaused
            },
            postHeartbeat: { url, key, paused in
                await recorder.recordAndPark(url: url, key: key, paused: paused)
            }
        )

        await service.configure(serverURL: "http://test.invalid", serverKey: "k1")
        await recorder.waitForPost(1)
        pauseState.isPaused = true
        await recorder.releasePost(1)
        await recorder.waitForPost(2)
        pauseState.isPaused = false
        await recorder.releasePost(2)
        await recorder.waitForPost(3)
        await service.stop()
        await recorder.releaseAndWaitForPostExit(3)

        let calls = await recorder.recordedCalls()
        #expect(calls.contains { $0.paused })
        #expect(calls.contains { !$0.paused })
    }
}
