// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("JournalReadinessGate")
struct JournalReadinessGateTests {
    @Test func identityBoundMarkerReturnsReady() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        try writeMarkerFiles(root: runtime.layout.rootURL, pid: 4242, startTime: 1_000.0)
        let gate = JournalReadinessGate(clock: AdvancingReadinessClock(), pollInterval: .milliseconds(1))

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil },
            identityProvider: {
                SupervisedChildIdentity(pid: 4242, kernelStartTime: 1_000.0, generation: 1)
            },
            readinessAcceptance: { _ in true }
        )

        #expect(result == .ready)
    }

    @Test func pidComparisonIsExact() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        try writeMarkerFiles(root: runtime.layout.rootURL, pid: 4242, startTime: 1_000.0)
        let clock = AdvancingReadinessClock()
        let gate = JournalReadinessGate(clock: clock, pollInterval: .milliseconds(1))

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil },
            identityProvider: {
                SupervisedChildIdentity(pid: 4243, kernelStartTime: 1_000.0, generation: 1)
            },
            readinessAcceptance: { _ in true }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
        #expect(clock.now() == .milliseconds(3))
    }

    @Test func startTimeToleranceAppliesOnlyToKernelStartTime() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        try writeMarkerFiles(root: runtime.layout.rootURL, pid: 4242, startTime: 1_000.0)
        let gate = JournalReadinessGate(clock: AdvancingReadinessClock(), pollInterval: .milliseconds(1))

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil },
            identityProvider: {
                SupervisedChildIdentity(pid: 4242, kernelStartTime: 1_001.5, generation: 1)
            },
            readinessAcceptance: { _ in true }
        )

        #expect(result == .ready)
    }

    @Test func startTimeBeyondToleranceIsNotReady() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        try writeMarkerFiles(root: runtime.layout.rootURL, pid: 4242, startTime: 1_000.0)
        let clock = AdvancingReadinessClock()
        let gate = JournalReadinessGate(clock: clock, pollInterval: .milliseconds(1))

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil },
            identityProvider: {
                SupervisedChildIdentity(pid: 4242, kernelStartTime: 1_001.501, generation: 1)
            },
            readinessAcceptance: { _ in true }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
    }

    @Test func staleReadyMarkerStartTimeIsNotReadyForRecycledPID() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        try writeMarkerFiles(
            root: runtime.layout.rootURL,
            pid: 4242,
            startTime: 1_000.0,
            supervisorStartTime: 2_000.0
        )
        let clock = AdvancingReadinessClock()
        let gate = JournalReadinessGate(clock: clock, pollInterval: .milliseconds(1))

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil },
            identityProvider: {
                SupervisedChildIdentity(pid: 4242, kernelStartTime: 2_000.0, generation: 1)
            },
            readinessAcceptance: { _ in true }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
    }

    @Test func missingOrPartialMarkersAreNotReadyByDefault() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        try FileManager.default.createDirectory(
            at: runtime.layout.rootURL.appendingPathComponent("health", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(#"{"pid":4242,"ready_at":1000.0,"start_time":1000.0}"#.utf8)
            .write(to: runtime.layout.rootURL.appendingPathComponent("health/supervisor.ready"))
        let clock = AdvancingReadinessClock()
        let gate = JournalReadinessGate(clock: clock, pollInterval: .milliseconds(1))

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil },
            identityProvider: {
                SupervisedChildIdentity(pid: 4242, kernelStartTime: 1_000.0, generation: 1)
            },
            readinessAcceptance: { _ in true }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
    }

    @Test func bakMarkersAreIgnored() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        try writeMarkerFiles(root: runtime.layout.rootURL, pid: 4242, startTime: 1_000.0, suffix: ".bak")
        let clock = AdvancingReadinessClock()
        let gate = JournalReadinessGate(clock: clock, pollInterval: .milliseconds(1))

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil },
            identityProvider: {
                SupervisedChildIdentity(pid: 4242, kernelStartTime: 1_000.0, generation: 1)
            },
            readinessAcceptance: { _ in true }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
    }

    @Test func terminalCheckFailsImmediatelyBeforeDeadline() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        let clock = AdvancingReadinessClock()
        let diagnostic = JournalDiagnostic(
            commandLabel: "journal start --hosted-parent",
            outputExcerpt: UICopy.JOURNAL_CHILD_BREAKER_TRIPPED
        )
        let gate = JournalReadinessGate(clock: clock, pollInterval: .milliseconds(1))

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .seconds(120),
            terminalCheck: { diagnostic },
            identityProvider: { nil },
            readinessAcceptance: { _ in true }
        )

        #expect(result == .failedTerminal(diagnostic))
        #expect(clock.now() == .zero)
    }

    @Test func rejectedCandidateKeepsPollingInsteadOfAcceptingStaleReadiness() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        try writeMarkerFiles(root: runtime.layout.rootURL, pid: 4242, startTime: 1_000.0)
        let clock = AdvancingReadinessClock()
        let gate = JournalReadinessGate(clock: clock, pollInterval: .milliseconds(1))
        let attempts = ReadinessAcceptanceRecorder()

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil },
            identityProvider: {
                SupervisedChildIdentity(pid: 4242, kernelStartTime: 1_000.0, generation: 2)
            },
            readinessAcceptance: { identity in
                attempts.append(identity)
                return false
            }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
        #expect(attempts.identities().allSatisfy { $0.generation == 2 })
        #expect(attempts.identities().count == 3)
    }
}

private final class ReadinessAcceptanceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SupervisedChildIdentity] = []

    func append(_ identity: SupervisedChildIdentity) {
        lock.withLock { values.append(identity) }
    }

    func identities() -> [SupervisedChildIdentity] {
        lock.withLock { values }
    }
}

private func writeMarkerFiles(
    root: URL,
    pid: pid_t,
    startTime: Double,
    supervisorStartTime: Double? = nil,
    suffix: String = ""
) throws {
    let health = root.appendingPathComponent("health", isDirectory: true)
    try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
    try Data(#"{"pid":\#(pid),"ready_at":1000.0,"start_time":\#(startTime)}"#.utf8)
        .write(to: health.appendingPathComponent("supervisor.ready\(suffix)"))
    try Data("\(pid)\n".utf8)
        .write(to: health.appendingPathComponent("supervisor.pid\(suffix)"))
    try Data("\(supervisorStartTime ?? startTime)\n".utf8)
        .write(to: health.appendingPathComponent("supervisor.start_time\(suffix)"))
}

private final class AdvancingReadinessClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero

    func now() -> Duration {
        lock.withLock { value }
    }

    func sleep(for duration: Duration) async {
        lock.withLock { value += duration }
        await Task.yield()
    }
}
