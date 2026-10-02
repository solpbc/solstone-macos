// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("SystemAudioRecovery", .serialized)
@MainActor
struct SystemAudioRecoveryTests {
    private var failure: Error { NSError(domain: "AudioRecoveryTest", code: 1) }

    @Test func detachmentWaitsForAdmittedSystemAudio() async throws {
        let output = SystemAudioStreamOutput()
        let entered = LockedCounter(), accepted = LockedCounter(), detaching = LockedCounter(), detached = LockedCounter()
        let release = DispatchSemaphore(value: 0)
        output.onAudioBuffer = { _ in entered.increment(); release.wait(); accepted.increment() }
        let delivery = Task.detached { output.deliverAudio(try makeNonSilentAudioSampleBuffer(seconds: 0.02)) }
        await entered.waitUntilCount(1)
        let detach = Task.detached {
            detaching.increment()
            output.onAudioBuffer = nil
            detached.increment()
        }
        await detaching.waitUntilCount(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(detached.count == 0)
        release.signal()
        try await delivery.value
        await detach.value
        #expect(accepted.count == 1)
        #expect(detached.count == 1)
        output.deliverAudio(try makeNonSilentAudioSampleBuffer(seconds: 0.02))
        #expect(accepted.count == 1)
    }

    @Test func errorRecoveryKeepsCurrentDestinationAfterReusedStart() async throws {
        let factory = FakeCaptureStreamFactory([FakeCaptureStream(), FakeCaptureStream()])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        defer { manager.clearCallback() }
        try await manager.start(filter: SCContentFilter())
        let originalID = try #require(manager._activeStreamIDForTesting)
        let received = LockedCounter()
        manager.setCallback { _ in received.increment() }
        try await manager.start(filter: SCContentFilter())
        manager._restartParkHookForTesting = {}
        await manager._handleStreamErrorForTesting(failure, from: originalID)
        manager._streamOutputForTesting?.onAudioBuffer?(try makeNonSilentAudioSampleBuffer(seconds: 0.02))
        #expect(received.count == 1)
        #expect(manager.isRunning)
        #expect(factory.createdStreams.count == 2)
        await manager._handleStreamErrorForTesting(failure, from: originalID)
        #expect(factory.createdStreams.count == 2)
        await manager.stop()
    }

    @Test(arguments: [false, true])
    func destinationChangeDuringRecoveryWins(clearOnly: Bool) async throws {
        let factory = FakeCaptureStreamFactory([FakeCaptureStream(), FakeCaptureStream()])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        try await manager.start(filter: SCContentFilter())
        let old = LockedCounter()
        let current = LockedCounter()
        manager.setCallback { _ in old.increment() }
        let retiredOutput = try #require(manager._streamOutputForTesting)
        let gate = OneShotContinuationGate()
        let parked = LockedCounter()
        manager._restartParkHookForTesting = {
            parked.increment()
            await gate.wait()
        }
        let task = Task { await manager._restartStreamForTesting() }
        await parked.waitUntilCount(1)
        manager.clearCallback()
        if !clearOnly { manager.setCallback { _ in current.increment() } }
        retiredOutput.onAudioBuffer?(try makeNonSilentAudioSampleBuffer(seconds: 0.02))
        #expect(retiredOutput.onAudioBuffer == nil)
        gate.release()
        await task.value
        manager._streamOutputForTesting?.onAudioBuffer?(try makeNonSilentAudioSampleBuffer(seconds: 0.02))
        #expect(old.count == 0)
        #expect(current.count == (clearOnly ? 0 : 1))
        #expect((manager.onAudioBuffer == nil) == clearOnly)
        await manager.stop()
    }

    @Test func failedRestartRemainsRetryableAndReportsFailure() async throws {
        let factory = FakeCaptureStreamFactory([
            FakeCaptureStream(), FakeCaptureStream(startError: failure), FakeCaptureStream(),
        ])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        try await manager.start(filter: SCContentFilter())
        manager._restartParkHookForTesting = {}
        let errors = LockedCounter()
        let received = LockedCounter()
        manager.setCallback(onError: { _ in errors.increment() }) { _ in received.increment() }
        await manager._handleStreamErrorForTesting(failure)
        #expect(!manager.isRunning)
        #expect(errors.count == 2)
        await manager._performHealthCheckForTesting()
        #expect(manager.isRunning)
        manager._streamOutputForTesting?.onAudioBuffer?(try makeNonSilentAudioSampleBuffer(seconds: 0.02))
        #expect(received.count == 1)
        await manager.stop()
    }

    @Test func timedOutStartCannotCommitItsLateResult() async throws {
        let gate = OneShotContinuationGate()
        let stream = FakeCaptureStream(startGates: [gate])
        let factory = FakeCaptureStreamFactory([stream])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory, operationTimeoutSeconds: 0.02)
        do {
            try await manager.start(filter: SCContentFilter())
            Issue.record("Expected a timeout")
        } catch is TimeoutError {}
        #expect(!manager.isRunning)
        gate.release()
        await stream.stopCount.waitUntilCount(1)
        #expect(!manager.isRunning)
        #expect(manager._streamOutputForTesting == nil)
        await manager.stop()
    }
}
