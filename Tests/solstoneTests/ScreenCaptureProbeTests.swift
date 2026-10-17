// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

private final class FakeProbeProcess: ScreenCaptureProbeProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var terminationCount = 0
    private var exitResult: ScreenCaptureProbeProcessExit?
    private var waitContinuation: CheckedContinuation<ScreenCaptureProbeProcessExit, Never>?
    private var hasStoredWaitContinuation = false

    init(exitResult: ScreenCaptureProbeProcessExit? = nil) {
        self.exitResult = exitResult
    }

    var terminateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminationCount
    }

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasStoredWaitContinuation
    }

    func terminate() {
        lock.lock()
        terminationCount += 1
        lock.unlock()
    }

    func waitForExit() async -> ScreenCaptureProbeProcessExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitResult {
                lock.unlock()
                continuation.resume(returning: exitResult)
            } else {
                waitContinuation = continuation
                hasStoredWaitContinuation = true
                lock.unlock()
            }
        }
    }

    func resumeWait(with result: ScreenCaptureProbeProcessExit) {
        lock.lock()
        let c = waitContinuation
        waitContinuation = nil
        hasStoredWaitContinuation = false
        lock.unlock()
        c?.resume(returning: result)
    }
}

@Suite("Screen capture probe")
struct ScreenCaptureProbeTests {
    @Test func exitMapping() async {
        let handle0 = FakeProbeProcess(exitResult: .exited(code: 0, reason: .exit))
        let result0 = await runScreenCaptureProbe(handle: handle0, timeout: .seconds(10))
        #expect(result0 == .granted)
        #expect(handle0.terminateCount == 0)

        let handle1 = FakeProbeProcess(exitResult: .exited(code: 1, reason: .exit))
        let result1 = await runScreenCaptureProbe(handle: handle1, timeout: .seconds(10))
        #expect(result1 == .denied)
        #expect(handle1.terminateCount == 0)

        let handle2 = FakeProbeProcess(exitResult: .exited(code: 2, reason: .exit))
        let result2 = await runScreenCaptureProbe(handle: handle2, timeout: .seconds(10))
        #expect(result2 == .unavailable(.unexpectedExit))
        #expect(handle2.terminateCount == 0)

        let handleFailed = FakeProbeProcess(exitResult: .failedToLaunch)
        let resultFailed = await runScreenCaptureProbe(handle: handleFailed, timeout: .seconds(10))
        #expect(resultFailed == .unavailable(.launchFailure))
        #expect(handleFailed.terminateCount == 0)

        let handleSignal = FakeProbeProcess(exitResult: .exited(code: 1, reason: .uncaughtSignal))
        let resultSignal = await runScreenCaptureProbe(handle: handleSignal, timeout: .seconds(10))
        #expect(resultSignal == .unavailable(.signal))
        #expect(handleSignal.terminateCount == 0)
    }

    @Test func timeoutInvokesTerminateOnce() async {
        let handle = FakeProbeProcess()
        let result = await runScreenCaptureProbe(handle: handle, timeout: .milliseconds(50))
        #expect(result == .unavailable(.timeout))
        #expect(handle.terminateCount == 1)
        handle.resumeWait(with: .exited(code: 0, reason: .exit))
    }

    @Test func cancelInvokesTerminateOnceAndDoesNotCrashOnSecondResume() async {
        let handle = FakeProbeProcess()
        let task = Task {
            await runScreenCaptureProbe(handle: handle, timeout: .seconds(10))
        }
        let start = Date()
        while !handle.isWaiting {
            if Date().timeIntervalSince(start) > 2.0 {
                Issue.record("Timed out waiting for waitForExit to store continuation")
                task.cancel()
                return
            }
            await Task.yield()
        }
        task.cancel()
        let result = await task.value
        #expect(result == .unavailable(.cancelled))
        #expect(handle.terminateCount == 1)
        handle.resumeWait(with: .exited(code: 0, reason: .exit))
    }

    @Test func argumentFunctionParsing() {
        var called = false
        let code0 = screenCaptureProbeExitCode(arguments: ["solstone", "--probe-screen-capture-access"], preflight: {
            called = true
            return true
        })
        #expect(code0 == 0)
        #expect(called)

        called = false
        let code1 = screenCaptureProbeExitCode(arguments: ["solstone", "--probe-screen-capture-access"], preflight: {
            called = true
            return false
        })
        #expect(code1 == 1)
        #expect(called)

        called = false
        let nil1 = screenCaptureProbeExitCode(arguments: ["solstone"], preflight: {
            called = true
            return true
        })
        #expect(nil1 == nil)
        #expect(!called)

        called = false
        let nil2 = screenCaptureProbeExitCode(arguments: ["solstone", "--other"], preflight: {
            called = true
            return true
        })
        #expect(nil2 == nil)
        #expect(!called)

        called = false
        let nil3 = screenCaptureProbeExitCode(arguments: [], preflight: {
            called = true
            return true
        })
        #expect(nil3 == nil)
        #expect(!called)
    }

    @Test @MainActor func defaultProviderReturnsMissingExecutable() async {
        let provider = ScreenRecordingPermissionProvider(
            hasPrompted: { false },
            preflight: { false },
            checkScreenRecording: { false },
            resetPromptedFlag: {}
        )
        let result = await provider.probe()
        #expect(result == .unavailable(.missingExecutable))
    }

    @Test @MainActor func snapshotCaptureInstalledProbeReturnsMissingExecutable() async {
        let state = AppState.forSnapshot()
        let result = await state.capture.runInstalledScreenRecordingProbe()
        #expect(result == .unavailable(.missingExecutable))
    }
}
