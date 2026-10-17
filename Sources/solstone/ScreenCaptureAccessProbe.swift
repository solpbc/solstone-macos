// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

internal enum ScreenCaptureProbeResult: Equatable, Sendable {
    case granted
    case denied
    case unavailable(ScreenCaptureProbeUnavailableReason)
}

internal enum ScreenCaptureProbeUnavailableReason: String, Equatable, Sendable, Error {
    case timeout
    case launchFailure = "launch-failure"
    case missingExecutable = "missing-executable"
    case signal
    case unexpectedExit = "unexpected-exit"
    case cancelled // runner-only; coordinator never logs or counts it
}

internal enum ScreenCaptureProbeTerminationReason: Equatable, Sendable {
    case exit
    case uncaughtSignal
}

internal enum ScreenCaptureProbeProcessExit: Equatable, Sendable {
    case exited(code: Int32, reason: ScreenCaptureProbeTerminationReason)
    case failedToLaunch
}

internal protocol ScreenCaptureProbeProcess: Sendable {
    func waitForExit() async -> ScreenCaptureProbeProcessExit
    func terminate()
}

internal func mapScreenCaptureProcessExit(_ exit: ScreenCaptureProbeProcessExit) -> ScreenCaptureProbeResult {
    switch exit {
    case .exited(let code, let reason):
        switch reason {
        case .exit:
            if code == 0 {
                return .granted
            } else if code == 1 {
                return .denied
            } else {
                return .unavailable(.unexpectedExit)
            }
        case .uncaughtSignal:
            return .unavailable(.signal)
        }
    case .failedToLaunch:
        return .unavailable(.launchFailure)
    }
}

internal func screenCaptureProbeExitCode(arguments: [String], preflight: () -> Bool) -> Int32? {
    guard arguments.count > 1 else { return nil }
    let remaining = Array(arguments.dropFirst())
    guard remaining == ["--probe-screen-capture-access"] else { return nil }
    return preflight() ? 0 : 1
}

private final class ScreenCaptureProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: any ScreenCaptureProbeProcess
    private var continuation: CheckedContinuation<ScreenCaptureProbeResult, Never>?
    private var sleepTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var hasResumed = false
    private var hasTerminated = false

    init(handle: any ScreenCaptureProbeProcess) {
        self.handle = handle
    }

    func begin(
        timeout: Duration,
        continuation: CheckedContinuation<ScreenCaptureProbeResult, Never>
    ) {
        lock.lock()
        if hasResumed {
            lock.unlock()
            continuation.resume(returning: .unavailable(.cancelled))
            return
        }
        self.continuation = continuation
        lock.unlock()

        let sleepTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.handleTimeout()
            } catch {
                // Sleep cancelled
            }
        }

        let waitTask = Task { [weak self] in
            guard let self else { return }
            let exit = await self.handle.waitForExit()
            self.handleExit(exit)
        }

        lock.lock()
        self.sleepTask = sleepTask
        self.waitTask = waitTask
        lock.unlock()
    }

    private func finish(result: ScreenCaptureProbeResult, terminate: Bool) {
        lock.lock()
        if hasResumed {
            lock.unlock()
            return
        }
        hasResumed = true
        let shouldTerminate: Bool
        if terminate && !hasTerminated {
            hasTerminated = true
            shouldTerminate = true
        } else {
            shouldTerminate = false
        }
        let c = continuation
        continuation = nil
        let sleep = sleepTask
        sleepTask = nil
        let wait = waitTask
        waitTask = nil
        lock.unlock()

        sleep?.cancel()
        wait?.cancel()
        if shouldTerminate {
            handle.terminate()
        }
        c?.resume(returning: result)
    }

    func handleExit(_ exit: ScreenCaptureProbeProcessExit) {
        finish(result: mapScreenCaptureProcessExit(exit), terminate: false)
    }

    func handleTimeout() {
        finish(result: .unavailable(.timeout), terminate: true)
    }

    func handleCancel() {
        finish(result: .unavailable(.cancelled), terminate: true)
    }
}

internal func runScreenCaptureProbe(
    handle: any ScreenCaptureProbeProcess,
    timeout: Duration
) async -> ScreenCaptureProbeResult {
    let gate = ScreenCaptureProbeGate(handle: handle)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            gate.begin(timeout: timeout, continuation: continuation)
        }
    } onCancel: {
        gate.handleCancel()
    }
}

final class ScreenCaptureProbeRealProcess: ScreenCaptureProbeProcess, @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var terminated = false

    init(pid: pid_t) {
        self.pid = pid
    }

    func waitForExit() async -> ScreenCaptureProbeProcessExit {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { [pid] in
                var status: Int32 = 0
                let result = waitpid(pid, &status, 0)
                guard result == pid else {
                    continuation.resume(returning: .exited(code: -1, reason: .exit))
                    return
                }
                let low7 = status & 0x7f
                if low7 == 0 {
                    let code = (status >> 8) & 0xff
                    continuation.resume(returning: .exited(code: code, reason: .exit))
                } else if low7 != 0x7f {
                    continuation.resume(returning: .exited(code: low7, reason: .uncaughtSignal))
                } else {
                    continuation.resume(returning: .exited(code: -1, reason: .exit))
                }
            }
        }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if !terminated {
            terminated = true
            kill(pid, SIGTERM)
        }
    }
}

internal func spawnScreenCaptureProbeProcess() -> Result<any ScreenCaptureProbeProcess, ScreenCaptureProbeUnavailableReason> {
    guard let executableURL = Bundle.main.executableURL else {
        return .failure(.missingExecutable)
    }
    let executablePath = executableURL.path

    var fileActions: posix_spawn_file_actions_t? = nil
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
        return .failure(.launchFailure)
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    guard posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0) == 0,
          posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0) == 0,
          posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0) == 0 else {
        return .failure(.launchFailure)
    }

    var attr: posix_spawnattr_t? = nil
    guard posix_spawnattr_init(&attr) == 0 else {
        return .failure(.launchFailure)
    }
    defer { posix_spawnattr_destroy(&attr) }

    guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
        return .failure(.launchFailure)
    }

    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup(executablePath),
        strdup("--probe-screen-capture-access"),
        nil
    ]
    defer {
        for arg in argv where arg != nil {
            free(arg)
        }
    }

    var pid: pid_t = 0
    let spawnResult = posix_spawn(&pid, executablePath, &fileActions, &attr, argv, environ)
    guard spawnResult == 0 else {
        return .failure(.launchFailure)
    }

    return .success(ScreenCaptureProbeRealProcess(pid: pid))
}

internal func executeLiveScreenCaptureProbe() async -> ScreenCaptureProbeResult {
    switch spawnScreenCaptureProbeProcess() {
    case .success(let handle):
        return await runScreenCaptureProbe(handle: handle, timeout: .seconds(3))
    case .failure(let reason):
        return .unavailable(reason)
    }
}
