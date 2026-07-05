// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin
import Testing
@testable import JournalRuntime

@Suite("SubprocessRunner")
struct SubprocessRunnerTests {
    @Test func subprocessRunner_drainsLargeInterleavedOutput() async throws {
        let runner = SubprocessRunner()
        let stdout = LockedData()
        let stderr = LockedData()

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "for i in $(seq 1 5000); do echo \"stdout line $i\"; echo \"stderr line $i\" >&2; done"],
            environment: nil,
            stdoutHandler: { stdout.append($0) },
            stderrHandler: { stderr.append($0) }
        )

        #expect(result.exitCode == 0)
        #expect(stdout.count > 64 * 1024)
        #expect(stderr.count > 64 * 1024)
        #expect(stdout.string.contains("stdout line 5000"))
        #expect(stderr.string.contains("stderr line 5000"))
    }

    @Test func subprocessRunner_capturesExitCode() async throws {
        let runner = SubprocessRunner()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "exit 7"],
            environment: nil,
            stdoutHandler: { _ in },
            stderrHandler: { _ in }
        )

        #expect(result.exitCode == 7)
    }

    @Test func subprocessRunner_throwsOnInvalidExecutable() async {
        let runner = SubprocessRunner()
        var didThrow = false
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/tmp/not-a-real-solstone-executable"),
                arguments: [],
                environment: nil,
                stdoutHandler: { _ in },
                stderrHandler: { _ in }
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }

    @Test func cancel_terminatesProcessesWithinGrace() async throws {
        let runner = SubprocessRunner()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", "trap '' TERM; sleep 30"],
                environment: nil,
                stdoutHandler: { _ in },
                stderrHandler: { _ in }
            )
        }

        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        runner.cancelAll()
        let result = try await task.value
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 3.0)
        #expect(result.terminationReason == .uncaughtSignal)
        #expect(result.exitCode == SIGKILL || result.exitCode == SIGTERM)
    }

    @Test func timeoutTerminatesProcess() async throws {
        let signals = LockedSignals()
        let runner = SubprocessRunner(
            pidExists: { pid in
                if Darwin.kill(pid, 0) == 0 { return true }
                return errno == EPERM
            },
            terminate: { pid, signal in
                signals.append(signal)
                return Darwin.kill(pid, signal)
            },
            timeoutGracePeriod: .milliseconds(10)
        )

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: nil,
            timeout: .milliseconds(50),
            stdoutHandler: { _ in },
            stderrHandler: { _ in }
        )

        #expect(result.terminationReason == .uncaughtSignal)
        #expect(signals.values.contains(SIGTERM))
    }

    @Test func timeoutHandleScheduleAfterCancelDoesNotTerminate() async throws {
        let signals = LockedSignals()
        let handle = SubprocessTimeoutHandle()

        handle.cancel()
        handle.schedule(
            timeout: .milliseconds(10),
            gracePeriod: .milliseconds(1),
            pid: 12345,
            pidExists: { _ in true },
            terminate: { _, signal in
                signals.append(signal)
                return 0
            }
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(signals.values.isEmpty)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}

private final class LockedSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []

    var values: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ signal: Int32) {
        lock.lock()
        recorded.append(signal)
        lock.unlock()
    }
}
