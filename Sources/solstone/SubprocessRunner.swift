// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Dispatch
import Foundation

internal protocol SubprocessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult

    func cancelAll()
}

extension SubprocessRunning {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        try await run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: nil,
            stdoutHandler: stdoutHandler,
            stderrHandler: stderrHandler
        )
    }
}

internal struct SubprocessResult: Sendable, Equatable {
    internal let exitCode: Int32
    internal let terminationReason: Process.TerminationReason
}

internal final class SubprocessRunner: SubprocessRunning {
    private let registry = RunningProcessRegistry()
    private let pidExists: @Sendable (pid_t) -> Bool
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let timeoutGracePeriod: Duration

    internal init(
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        timeoutGracePeriod: Duration = .seconds(2)
    ) {
        self.pidExists = pidExists
        self.terminate = terminate
        self.timeoutGracePeriod = timeoutGracePeriod
    }

    internal func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Explicit inheritance: when caller passes nil, fall back to the .app's
            // own environment. process.environment = nil documents as "inherit" but
            // in Foundation.Process under some launch contexts an empty/minimal env
            // is delivered to the subprocess instead. Pass the calling process's env
            // explicitly to guarantee PATH and friends survive into the subprocess.
            // (Verified 2026-05-12 during solstone-macos installer cold smoke —
            // sol doctor checks for npx/ioreg/lsof failed because PATH arrived
            // empty in the subprocess despite the parent .app having a rich PATH.)
            process.environment = environment ?? ProcessInfo.processInfo.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutDrain = DrainBuffer(
                fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
                chunkHandler: stdoutHandler
            )
            let stderrDrain = DrainBuffer(
                fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor,
                chunkHandler: stderrHandler
            )

            let processToken = UUID()
            let timeoutHandle = SubprocessTimeoutHandle()
            let completion = SubprocessCompletion(
                continuation: continuation,
                cleanup: { [registry, processToken, timeoutHandle] in
                    timeoutHandle.cancel()
                    registry.deregister(processToken)
                }
            )

            let queue = DispatchQueue(label: "app.solstone.observer.subprocess.\(UUID().uuidString)")
            let stdoutSource = DispatchSource.makeReadSource(
                fileDescriptor: stdoutDrain.fileDescriptor,
                queue: queue
            )
            let stderrSource = DispatchSource.makeReadSource(
                fileDescriptor: stderrDrain.fileDescriptor,
                queue: queue
            )

            stdoutSource.setEventHandler { [stdoutDrain, completion] in
                if stdoutDrain.drainAvailable() {
                    stdoutSource.cancel()
                    Task {
                        await completion.markStdoutEOF()
                    }
                }
            }
            stderrSource.setEventHandler { [stderrDrain, completion] in
                if stderrDrain.drainAvailable() {
                    stderrSource.cancel()
                    Task {
                        await completion.markStderrEOF()
                    }
                }
            }

            process.terminationHandler = { proc in
                timeoutHandle.cancel()
                let result = SubprocessResult(
                    exitCode: proc.terminationStatus,
                    terminationReason: proc.terminationReason
                )
                if stdoutDrain.drainAvailable() {
                    Task {
                        await completion.markStdoutEOF()
                    }
                }
                if stderrDrain.drainAvailable() {
                    Task {
                        await completion.markStderrEOF()
                    }
                }
                Task {
                    await completion.setResult(result)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(500)) {
                    Task {
                        await completion.forceResume(result)
                    }
                    stdoutSource.cancel()
                    stderrSource.cancel()
                }
            }

            do {
                registry.register(process, token: processToken)
                try process.run()
                if let timeout {
                    timeoutHandle.schedule(
                        timeout: timeout,
                        gracePeriod: timeoutGracePeriod,
                        pid: process.processIdentifier,
                        pidExists: pidExists,
                        terminate: terminate
                    )
                }
                stdoutSource.resume()
                stderrSource.resume()
            } catch {
                stdoutSource.cancel()
                stderrSource.cancel()
                timeoutHandle.cancel()
                registry.deregister(processToken)
                continuation.resume(throwing: error)
            }
        }
    }

    internal func cancelAll() {
        registry.cancelAll()
    }
}

internal final class SubprocessTimeoutHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func schedule(
        timeout: Duration,
        gracePeriod: Duration,
        pid: pid_t,
        pidExists: @escaping @Sendable (pid_t) -> Bool,
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32
    ) {
        let newTask = Task.detached { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, self?.isCancelled == false else { return }
            _ = terminate(pid, SIGTERM)
            try? await Task.sleep(for: gracePeriod)
            guard !Task.isCancelled, self?.isCancelled == false else { return }
            if pidExists(pid) {
                _ = terminate(pid, SIGKILL)
            }
        }
        var shouldCancel = false
        lock.lock()
        if cancelled {
            shouldCancel = true
        } else {
            task = newTask
        }
        lock.unlock()
        if shouldCancel {
            newTask.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        task = nil
        lock.unlock()
        current?.cancel()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class DrainBuffer: @unchecked Sendable {
    internal let fileDescriptor: Int32

    private let lock = NSLock()
    private var didReachEOF = false
    private let chunkHandler: @Sendable (Data) -> Void

    init(fileDescriptor: Int32, chunkHandler: @escaping @Sendable (Data) -> Void) {
        self.fileDescriptor = fileDescriptor
        self.chunkHandler = chunkHandler

        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    func drainAvailable() -> Bool {
        if isEOF {
            return true
        }

        var reachedEOF = false
        while true {
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)

            if count > 0 {
                chunkHandler(Data(buffer.prefix(count)))
                continue
            }

            if count == 0 {
                reachedEOF = true
                break
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }

            reachedEOF = true
            break
        }

        if reachedEOF {
            markEOF()
        }
        return reachedEOF
    }

    private var isEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didReachEOF
    }

    private func markEOF() {
        lock.lock()
        didReachEOF = true
        lock.unlock()
    }
}

private final class RunningProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]

    func register(_ process: Process, token: UUID) {
        lock.lock()
        processes[token] = process
        lock.unlock()
    }

    func deregister(_ token: UUID) {
        lock.lock()
        processes[token] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let active = processes
        lock.unlock()

        for process in active.values {
            if process.isRunning {
                process.terminate()
            }
        }

        let tokens = Array(active.keys)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            killStillRunning(tokens: tokens)
        }
    }

    private func killStillRunning(tokens: [UUID]) {
        lock.lock()
        let active = tokens.compactMap { processes[$0] }
        lock.unlock()

        for process in active {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

private actor SubprocessCompletion {
    private var stdoutEOF = false
    private var stderrEOF = false
    private var result: SubprocessResult?
    private var didResume = false
    private let continuation: CheckedContinuation<SubprocessResult, Error>
    private let cleanup: @Sendable () -> Void

    init(
        continuation: CheckedContinuation<SubprocessResult, Error>,
        cleanup: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.cleanup = cleanup
    }

    func markStdoutEOF() {
        stdoutEOF = true
        resumeIfReady()
    }

    func markStderrEOF() {
        stderrEOF = true
        resumeIfReady()
    }

    func setResult(_ newResult: SubprocessResult) {
        result = newResult
        resumeIfReady()
    }

    func forceResume(_ fallback: SubprocessResult) {
        guard !didResume else { return }
        didResume = true
        let resultToResume = result ?? fallback
        cleanup()
        continuation.resume(returning: resultToResume)
    }

    private func resumeIfReady() {
        guard !didResume, stdoutEOF, stderrEOF, let result else { return }
        didResume = true
        cleanup()
        continuation.resume(returning: result)
    }
}
