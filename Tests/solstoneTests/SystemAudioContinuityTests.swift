// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import SolstoneCore
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("System audio continuity", .serialized)
@MainActor
struct SystemAudioContinuityTests {
    private var failure: Error { NSError(domain: "ContinuityTest", code: 1) }
    private func manager(_ factory: FakeCaptureStreamFactory, _ observer: RestartObserverDouble,
                         timeout: Double = 0.05) -> SystemAudioCaptureManager {
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory, operationTimeoutSeconds: timeout,
            restartListenerFactory: observer.factory)
        manager._restartParkHookForTesting = {}
        return manager
    }
    private func settled(_ condition: @escaping @MainActor () -> Bool) async throws {
        try await withTimeout(seconds: 2) {
            while !(await condition()) { try await Task.sleep(for: .milliseconds(1)) }
        }
    }

    @Test func resetIsPromptCoalescedAndReplayedUntilCurrentPCM() async throws {
        let factory = FakeCaptureStreamFactory(), observer = RestartObserverDouble()
        let manager = manager(factory, observer), first = LockedCounter(), second = LockedCounter()
        try await manager.start(filter: SCContentFilter())
        manager.setCallback(onError: { _ in first.increment() }) { _ in }
        let staleObserver = observer.callbacks[0]
        for _ in 0..<30 { staleObserver() }
        #expect(first.count == 1 && observer.callbacks.count == 2 && observer.invalidations == 1)
        try await settled { factory.createdStreams.count == 2 && manager.isRunning }
        manager.clearCallback()
        manager.setCallback(onError: { _ in second.increment() }) { _ in }
        #expect(second.count == 1)
        let acknowledgements = LockedCounter()
        manager._ackParkHookForTesting = { acknowledgements.increment() }
        let output = try #require(manager._streamOutputForTesting)
        let invalid = try makeSilentAudioSampleBuffer(seconds: 0.02); CMSampleBufferInvalidate(invalid)
        output.deliverAudio(invalid)
        manager.clearCallback(); manager.setCallback(onError: { _ in second.increment() }) { _ in }
        #expect(second.count == 2 && acknowledgements.count == 0)
        output.deliverAudio(try makeSilentAudioSampleBuffer(seconds: 0.02))
        try await settled { acknowledgements.count == 1 }
        // Let the acknowledgement commit after the test hook returns.
        await Task.yield()
        manager.clearCallback(); manager.setCallback(onError: { _ in second.increment() }) { _ in }
        #expect(second.count == 2)
        await manager.stop(); staleObserver(); observer.callbacks.last?()
        await manager._performHealthCheckForTesting()
        #expect(factory.createdStreams.count == 2)
    }

    @Test func validAudioBurstCoalescesAcknowledgementWhileMainActorWorkIsPending() async throws {
        let factory = FakeCaptureStreamFactory(), observer = RestartObserverDouble(), manager = manager(factory, observer)
        try await manager.start(filter: SCContentFilter())
        let gate = OneShotContinuationGate(), parked = LockedCounter()
        manager._ackParkHookForTesting = { parked.increment(); await gate.wait() }
        let output = try #require(manager._streamOutputForTesting), pcm = try makeSilentAudioSampleBuffer(seconds: 0.02)
        output.deliverAudio(pcm)
        try await withTimeout(seconds: 1) { await parked.waitUntilCount(1) }
        for _ in 0..<1000 { output.deliverAudio(pcm) }
        await Task.yield()
        #expect(parked.count == 1)
        gate.release(); await Task.yield()
        for _ in 0..<100 { output.deliverAudio(pcm) }
        await Task.yield()
        #expect(parked.count == 1)
        await manager.stop()
    }

    @Test func queuedResetCannotRebuildAReplacementSession() async throws {
        let factory = FakeCaptureStreamFactory(), observer = RestartObserverDouble(), manager = manager(factory, observer)
        try await manager.start(filter: SCContentFilter())
        let gate = OneShotContinuationGate(), parked = LockedCounter()
        manager._resetAdmissionParkHookForTesting = { parked.increment(); await gate.wait() }
        observer.callbacks.last?()
        try await withTimeout(seconds: 1) { await parked.waitUntilCount(1) }
        await manager.stop()
        try await manager.start(filter: SCContentFilter())
        #expect(manager.isRunning && factory.createdStreams.count == 2)
        gate.release()
        try await settled { !manager._resetRecoveryScheduledForTesting }
        #expect(manager.isRunning && factory.createdStreams.count == 2 && factory.createdStreams[1].stopCount.count == 0)
        await manager.stop()
    }

    @Test func oldAcknowledgementCannotClearNewInterruption() async throws {
        let factory = FakeCaptureStreamFactory(), observer = RestartObserverDouble()
        let manager = manager(factory, observer), gate = OneShotContinuationGate(), parked = LockedCounter()
        try await manager.start(filter: SCContentFilter())
        manager._ackParkHookForTesting = { parked.increment(); await gate.wait() }
        manager._streamOutputForTesting?.deliverAudio(try makeSilentAudioSampleBuffer(seconds: 0.02))
        await parked.waitUntilCount(1)
        observer.callbacks.last?()
        try await settled { factory.createdStreams.count == 2 && manager.isRunning }
        gate.release(); await Task.yield()
        let replayed = LockedCounter()
        manager.setCallback(onError: { _ in replayed.increment() }) { _ in }
        #expect(replayed.count == 1)
        await manager.stop()
    }

    @Test func quietSuccessfulStartsCannotRenewRecoveryBudgetOrClaimLoss() async throws {
        let factory = FakeCaptureStreamFactory(), observer = RestartObserverDouble()
        let manager = manager(factory, observer), errors = LockedCounter()
        try await manager.start(filter: SCContentFilter())
        manager.setCallback(onError: { _ in errors.increment() }) { _ in }
        for _ in 0..<20 { await manager._performHealthCheckForTesting() }
        #expect(factory.createdStreams.count == 4 && errors.count == 0)
        // A real external reset admits a fresh bounded recovery batch.
        observer.callbacks.last?()
        try await settled { factory.createdStreams.count == 5 && manager.isRunning }
        #expect(errors.count == 1)
        await manager.stop()
    }

    @Test func failingStartsAreBoundedAcrossRotationAndHealthTicks() async throws {
        let factory = FakeCaptureStreamFactory([FakeCaptureStream()] + (0..<10).map { _ in FakeCaptureStream(startError: failure) })
        let observer = RestartObserverDouble(), manager = manager(factory, observer), errors = LockedCounter()
        try await manager.start(filter: SCContentFilter())
        manager.setCallback(onError: { _ in errors.increment() }) { _ in }
        observer.callbacks.last?()
        try await settled { factory.createdStreams.count == 4 && !manager.isRunning }
        for _ in 0..<10 { try await manager.start(filter: SCContentFilter()); await manager._performHealthCheckForTesting() }
        #expect(factory.createdStreams.count == 4 && errors.count == 4)
        let next = LockedCounter(); manager.clearCallback(); manager.setCallback(onError: { _ in next.increment() }) { _ in }
        #expect(next.count == 1)
        await manager.stop()
    }

    @Test(arguments: [SCStreamError.Code.userDeclined.rawValue, SCStreamError.Code.userStopped.rawValue])
    func terminalStopSuppressesResetAndHealthBeforeCoordinatorStops(code: Int) async throws {
        let factory = FakeCaptureStreamFactory(), observer = RestartObserverDouble(), manager = manager(factory, observer)
        let terminals = LockedCounter()
        manager.onTerminalStop = { terminals.increment() }
        try await manager.start(filter: SCContentFilter())
        await manager._handleStreamErrorForTesting(NSError(domain: SCStreamErrorDomain, code: code))
        for callback in observer.callbacks { callback() }
        for _ in 0..<5 { await manager._performHealthCheckForTesting() }
        #expect(factory.createdStreams.count == 1 && !manager.isRunning)
        #expect(terminals.count == (code == SCStreamError.Code.userStopped.rawValue ? 1 : 0))
        await manager.stop()
    }

    @Test func failedListenerRegistrationRetainsUsableTransportAndFallback() async throws {
        let factory = FakeCaptureStreamFactory(), observer = RestartObserverDouble(failRegistrations: [0])
        let manager = manager(factory, observer), errors = LockedCounter(), audio = LockedCounter()
        manager.setCallback(onError: { _ in errors.increment() }) { _ in audio.increment() }
        try await manager.start(filter: SCContentFilter())
        #expect(manager.isRunning && errors.count == 1)
        manager._streamOutputForTesting?.deliverAudio(try makeSilentAudioSampleBuffer(seconds: 0.02))
        #expect(audio.count == 1)
        for _ in 0..<3 { await manager._performHealthCheckForTesting() }
        #expect(factory.createdStreams.count == 2)
        await manager.stop()
    }

    @Test func unknownCleanupBlocksReplacementUntilPositiveCleanup() async throws {
        let old = FakeCaptureStream(stopError: failure), factory = FakeCaptureStreamFactory([old, FakeCaptureStream()])
        let observer = RestartObserverDouble(), manager = manager(factory, observer)
        try await manager.start(filter: SCContentFilter())
        observer.callbacks.last?()
        try await settled { old.stopCount.count == 1 }
        for _ in 0..<3 { await manager._performHealthCheckForTesting() }
        #expect(factory.createdStreams.count == 1 && !manager.isRunning)
        old.stopError = nil
        observer.callbacks.last?()
        try await settled { factory.createdStreams.count == 2 && manager.isRunning }
        #expect(old.stopCount.count >= 2)
        await manager.stop()
    }

    @Test func resetDuringFailedCleanupAdmitsRemainingAttemptPromptly() async throws {
        let gate = OneShotContinuationGate(), old = FakeCaptureStream(stopGates: [gate], stopError: failure)
        let factory = FakeCaptureStreamFactory([old, FakeCaptureStream()]), observer = RestartObserverDouble()
        let manager = manager(factory, observer), cleanupFailures = LockedCounter()
        try await manager.start(filter: SCContentFilter())
        manager.setCallback(onError: { error in
            if (error as NSError).domain == "ContinuityTest" { cleanupFailures.increment(); old.stopError = nil }
        }) { _ in }
        observer.callbacks.last?()
        try await withTimeout(seconds: 1) { await old.stopCount.waitUntilCount(1) }
        observer.callbacks.last?() // another real reset while the old cleanup is pending
        gate.release()
        try await settled { manager.isRunning && factory.createdStreams.count == 2 }
        #expect(cleanupFailures.count == 1 && old.stopCount.count == 2)
        await Task.yield()
        #expect(factory.createdStreams.count == 2) // coalesced reset did not cause another healthy rebuild
        await manager.stop()
    }

    @Test func hungOldStartCannotOverlapNewSessionAndLateStartCannotCommit() async throws {
        let gate = OneShotContinuationGate(), old = FakeCaptureStream(startGates: [gate])
        let factory = FakeCaptureStreamFactory([old, FakeCaptureStream()]), observer = RestartObserverDouble()
        let manager = manager(factory, observer, timeout: 0.02)
        do { try await manager.start(filter: SCContentFilter()); Issue.record("Expected timeout") } catch is TimeoutError {}
        await manager.stop()
        do { try await manager.start(filter: SCContentFilter()); Issue.record("Must retain pending native ownership") } catch {}
        #expect(factory.createdStreams.count == 1 && !manager.isRunning)
        gate.release()
        try await settled { old.stopCount.count >= 3 }
        await manager.stop()
        try await manager.start(filter: SCContentFilter())
        #expect(factory.createdStreams.count == 2 && manager.isRunning)
        await manager.stop()
    }

    @Test(arguments: [false, true])
    func staleInitialFailureCannotFaultOrEndNewSession(permission: Bool) async throws {
        let stopGate = OneShotContinuationGate()
        let error = permission ? NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue) : failure as NSError
        let old = FakeCaptureStream(stopGates: [stopGate], startError: error)
        let factory = FakeCaptureStreamFactory([old, FakeCaptureStream()]), observer = RestartObserverDouble()
        let manager = manager(factory, observer, timeout: 0.03)
        let original = Task { try? await manager.start(filter: SCContentFilter()) }
        try await withTimeout(seconds: 1) { await old.stopCount.waitUntilCount(1) }
        await manager.stop()
        let generation = manager._streamGenerationForTesting
        let next = Task { try await manager.start(filter: SCContentFilter()) }
        try await settled { manager._streamGenerationForTesting > generation }
        stopGate.release(); await original.value; try await next.value
        let errors = LockedCounter(); manager.setCallback(onError: { _ in errors.increment() }) { _ in }
        #expect(manager.isRunning && factory.createdStreams.count == 2 && errors.count == 0)
        await manager.stop()
    }

    @Test func staleInitialSuccessCannotRecoverOverNewSession() async throws {
        let startGate = OneShotContinuationGate(), firstStop = OneShotContinuationGate(), lateStop = OneShotContinuationGate()
        firstStop.release()
        let old = FakeCaptureStream(startGates: [startGate], stopGates: [firstStop, lateStop])
        let factory = FakeCaptureStreamFactory([old, FakeCaptureStream()]), observer = RestartObserverDouble()
        let manager = manager(factory, observer, timeout: 1)
        let original = Task { try? await manager.start(filter: SCContentFilter()) }
        try await withTimeout(seconds: 1) { await old.startCount.waitUntilCount(1) }
        await manager.stop(); startGate.release()
        try await withTimeout(seconds: 1) { await old.stopCount.waitUntilCount(2) }
        let generation = manager._streamGenerationForTesting
        let next = Task { try await manager.start(filter: SCContentFilter()) }
        try await settled { manager._streamGenerationForTesting > generation }
        lateStop.release(); await original.value; try await next.value
        #expect(manager.isRunning && factory.createdStreams.count == 2)
        #expect(factory.createdStreams[1].stopCount.count == 0)
        await manager.stop()
    }

    @Test func latestFilterFailureAndCleanupRemainBounded() async throws {
        let startGate = OneShotContinuationGate(), pending = FakeCaptureStream(startGates: [startGate], stopError: failure, updateError: failure)
        let factory = FakeCaptureStreamFactory([FakeCaptureStream(), pending, FakeCaptureStream()])
        let observer = RestartObserverDouble(), manager = manager(factory, observer)
        try await manager.start(filter: SCContentFilter())
        let task = Task { await manager._restartStreamForTesting() }
        await pending.startCount.waitUntilCount(1)
        let latest = SCContentFilter(); try await manager.start(filter: latest)
        startGate.release(); await task.value
        #expect(pending.updatedFilters.last === latest && !manager.isRunning && factory.createdStreams.count == 2)
        await manager._performHealthCheckForTesting()
        #expect(factory.createdStreams.count == 2)
        pending.stopError = nil
        observer.callbacks.last?()
        try await settled { factory.createdStreams.count == 3 && manager.isRunning }
        #expect(factory.createdFilters.last === latest)
        await manager.stop()
    }

    @Test func interruptionSpanningRealSegmentBoundarySealsBothAffectedSources() async throws {
        let root = try makeTempDirectory("system-continuity-boundary")
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = FakeCaptureStreamFactory(), observer = RestartObserverDouble(), manager = manager(factory, observer)
        let gate = OneShotContinuationGate(), parked = LockedCounter()
        manager._restartParkHookForTesting = { parked.increment(); await gate.wait() }
        let display = DisplayInfo(displayID: 42, width: 64, height: 64, bounds: CGRect(x: 0, y: 0, width: 64, height: 64))
        func writer(_ prefix: String) -> SegmentWriter {
            SegmentWriter(outputDirectory: root, timePrefix: prefix,
                screenshotCapturerFactory: { _, _, _, _, _, _ in FakeScreenshotCapturer() })
        }
        let first = writer("120000")
        _ = try await first.start(sources: .screen, displayInfos: [display], audioFilter: SCContentFilter(), systemAudioCaptureManager: manager)
        observer.callbacks.last?(); await parked.waitUntilCount(1)
        _ = await first.finishCapture()
        let second = writer("120100")
        _ = try await second.start(sources: .screen, displayInfos: [display], audioFilter: SCContentFilter(), systemAudioCaptureManager: manager)
        _ = await second.finishCapture()
        for prefix in ["120000", "120100"] {
            let data = try Data(contentsOf: root.appendingPathComponent("\(prefix)_meta.json"))
            let meta = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let capture = try #require(meta["audio_capture"] as? [String: Any])
            let sources = try #require(capture["sources"] as? [[String: Any]])
            let system = try #require(sources.first { $0["source_id"] as? String == "system" })
            #expect(capture["state"] as? String == "partial" && system["state"] as? String == "partial")
            #expect(!(system["failures"] as? [[String: Any]] ?? []).isEmpty)
        }
        gate.release(); await manager.stop()
    }
}

@MainActor
private final class RestartObserverDouble {
    var callbacks: [@MainActor () -> Void] = []
    var invalidations = 0
    let failRegistrations: Set<Int>
    init(failRegistrations: Set<Int> = []) { self.failRegistrations = failRegistrations }
    var factory: SystemAudioCaptureManager.RestartListenerFactory {
        { callback in
            let index = self.callbacks.count
            self.callbacks.append(callback)
            if self.failRegistrations.contains(index) { throw NSError(domain: "RestartListenerTest", code: 1) }
            return { self.invalidations += 1 }
        }
    }
}
