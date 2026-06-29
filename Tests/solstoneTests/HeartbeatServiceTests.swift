// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("HeartbeatService", .serialized)
struct HeartbeatServiceTests {
    private final class ManualMonotonicClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Duration = .zero

        func now() -> Duration {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func sleep(for duration: Duration) async {}

        func advance(seconds: Int64) {
            lock.lock()
            value += .seconds(seconds)
            lock.unlock()
        }
    }

    actor HeartbeatRecorder {
        private(set) var calls: [(url: String, key: String, paused: Bool, health: ObserverHealthSnapshot?)] = []
        private var postWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var releasedPosts: Set<Int> = []
        private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
        private var exitedPosts: Set<Int> = []
        private var exitWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

        func recordAndPark(url: String, key: String, paused: Bool, health: ObserverHealthSnapshot?) async {
            calls.append((url: url, key: key, paused: paused, health: health))
            let ordinal = calls.count
            resumePostWaiters()
            await waitForRelease(ordinal)
            markPostExited(ordinal)
        }

        func callCount() -> Int {
            calls.count
        }

        func recordedCalls() -> [(url: String, key: String, paused: Bool, health: ObserverHealthSnapshot?)] {
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

    @MainActor
    final class HealthStateBox {
        var snapshot = ObserverHealthSnapshot(
            name: "observer-one",
            streamType: "desktop",
            version: "first",
            uptimeSeconds: -1,
            lastSuccessfulSync: nil,
            pendingQueueDepth: 1,
            recentErrorCount: 0,
            lastErrorReason: nil
        )
    }

    private func resolver(url: String = "http://test.invalid") -> HomeBaseURLResolver {
        HomeBaseURLResolver { .url(url) }
    }

    actor ThrowingHeartbeatRecorder {
        private(set) var calls: [(url: String, key: String, paused: Bool, health: ObserverHealthSnapshot?)] = []
        private var postWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func record(url: String, key: String, paused: Bool, health: ObserverHealthSnapshot?) throws {
            calls.append((url: url, key: key, paused: paused, health: health))
            resumePostWaiters()

            switch calls.count {
            case 1:
                throw UploadError.serverError(statusCode: 503, message: "temporary")
            case 2:
                throw URLError(.timedOut)
            default:
                return
            }
        }

        func callCount() -> Int {
            calls.count
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

    actor HeartbeatCallCounter {
        private(set) var count = 0

        func record() {
            count += 1
        }
    }

    @Test func configureStartsLoopAndStopPreventsFurtherPosts() async {
        let recorder = HeartbeatRecorder()
        let service = HeartbeatService(
            intervalSeconds: 0,
            resolver: resolver(),
            isPaused: { false },
            healthProvider: { nil },
            postHeartbeat: { url, key, paused, health in
                await recorder.recordAndPark(url: url, key: key, paused: paused, health: health)
            }
        )

        await service.configure(serverKey: "k1")
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
        #expect(calls.allSatisfy { $0.health == nil })
    }

    @Test @MainActor func heartbeatReadsLatestPauseStateOnEachTick() async {
        let recorder = HeartbeatRecorder()
        let pauseState = PauseStateBox()
        let service = HeartbeatService(
            intervalSeconds: 0,
            resolver: resolver(),
            isPaused: { [pauseState] in
                pauseState.isPaused
            },
            healthProvider: { nil },
            postHeartbeat: { url, key, paused, health in
                await recorder.recordAndPark(url: url, key: key, paused: paused, health: health)
            }
        )

        await service.configure(serverKey: "k1")
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

    @Test @MainActor func heartbeatReadsLatestHealthSnapshotAndStampsUptimeOnEachTick() async {
        let recorder = HeartbeatRecorder()
        let healthState = HealthStateBox()
        let clock = ManualMonotonicClock()
        let service = HeartbeatService(
            intervalSeconds: 0,
            resolver: resolver(),
            isPaused: { false },
            healthProvider: { [healthState] in
                healthState.snapshot
            },
            postHeartbeat: { url, key, paused, health in
                await recorder.recordAndPark(url: url, key: key, paused: paused, health: health)
            },
            clock: clock
        )

        await service.configure(serverKey: "k1")
        await recorder.waitForPost(1)

        healthState.snapshot.version = "second"
        healthState.snapshot.pendingQueueDepth = 9
        clock.advance(seconds: 17)
        await recorder.releasePost(1)
        await recorder.waitForPost(2)
        await service.stop()
        await recorder.releaseAndWaitForPostExit(2)

        let calls = await recorder.recordedCalls()
        #expect(calls[0].health?.version == "first")
        #expect(calls[0].health?.pendingQueueDepth == 1)
        #expect(calls[0].health?.uptimeSeconds == 0)
        #expect(calls[1].health?.version == "second")
        #expect(calls[1].health?.pendingQueueDepth == 9)
        #expect(calls[1].health?.uptimeSeconds == 17)
    }

    @Test func heartbeatPostFailuresDoNotStopPeriodicLoop() async {
        let recorder = ThrowingHeartbeatRecorder()
        let service = HeartbeatService(
            intervalSeconds: 0,
            resolver: resolver(),
            isPaused: { false },
            healthProvider: { nil },
            postHeartbeat: { url, key, paused, health in
                try await recorder.record(url: url, key: key, paused: paused, health: health)
            }
        )

        await service.configure(serverKey: "k1")
        await recorder.waitForPost(3)
        await service.stop()

        #expect(await recorder.callCount() >= 3)
    }

    @Test @MainActor func appStateHeartbeatProviderIncludesLifecyclePausedState() async {
        let appState = AppState.forSnapshot()

        #expect(await appState.heartbeatService.pausedForTesting() == false)

        appState.isPaused = true
        #expect(await appState.heartbeatService.pausedForTesting() == true)

        appState.isPaused = false
        appState.pauseManager.pause(for: .indefinite)
        #expect(await appState.heartbeatService.pausedForTesting() == true)

        appState.pauseManager.resume()
    }

    @Test func heartbeatRealRequestUsesResolverLoopbackTarget() async {
        ObserverURLProtocol.store.reset()
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "{}")
        let client = UploadClient(sessionConfiguration: observerURLProtocolConfiguration())
        let service = HeartbeatService(
            intervalSeconds: 999,
            resolver: resolver(url: "http://127.0.0.1:24680"),
            isPaused: { false },
            healthProvider: { nil },
            postHeartbeat: { url, key, paused, health in
                try await client.postObserverStatus(
                    serverURL: url,
                    serverKey: key,
                    paused: paused,
                    health: health
                )
            }
        )

        await service.configure(serverKey: "k1")
        await ObserverURLProtocol.store.waitForRequestCount(1)
        await service.stop()

        let request = ObserverURLProtocol.store.snapshotRequests().first
        #expect(request?.url?.host == "127.0.0.1")
        #expect(request?.url?.port == 24680)
        #expect(request?.url?.path == "/app/observer/ingest/event")
    }

    @Test func heartbeatRealRequestUsesResolverStaticTarget() async {
        ObserverURLProtocol.store.reset()
        ObserverURLProtocol.store.enqueue(statusCode: 200, body: "{}")
        let client = UploadClient(sessionConfiguration: observerURLProtocolConfiguration())
        let service = HeartbeatService(
            intervalSeconds: 999,
            resolver: resolver(url: "https://journal.example:9443"),
            isPaused: { false },
            healthProvider: { nil },
            postHeartbeat: { url, key, paused, health in
                try await client.postObserverStatus(
                    serverURL: url,
                    serverKey: key,
                    paused: paused,
                    health: health
                )
            }
        )

        await service.configure(serverKey: "k1")
        await ObserverURLProtocol.store.waitForRequestCount(1)
        await service.stop()

        let request = ObserverURLProtocol.store.snapshotRequests().first
        #expect(request?.url?.host == "journal.example")
        #expect(request?.url?.port == 9443)
        #expect(request?.url?.path == "/app/observer/ingest/event")
    }

    @Test func heartbeatHeldResolverSkipsPost() async {
        ObserverURLProtocol.store.reset()
        let counter = HeartbeatCallCounter()
        let service = HeartbeatService(
            intervalSeconds: 999,
            resolver: HomeBaseURLResolver { .held },
            isPaused: { false },
            healthProvider: { nil },
            postHeartbeat: { _, _, _, _ in
                await counter.record()
            }
        )

        await service.configure(serverKey: "k1")
        try? await Task.sleep(for: .milliseconds(50))
        await service.stop()

        #expect(await counter.count == 0)
        #expect(ObserverURLProtocol.store.snapshotRequests().isEmpty)
    }
}
