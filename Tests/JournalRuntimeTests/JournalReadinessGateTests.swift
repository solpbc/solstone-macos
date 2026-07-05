// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("JournalReadinessGate")
struct JournalReadinessGateTests {
    @Test func probeRefusalKeepsWaitingEvenWhenMarkerExists() async throws {
        let runtime = try makeRuntime()
        let clock = AdvancingReadinessClock()
        let probe = SequencedAcceptProbe([false, false, false])
        let gate = JournalReadinessGate(
            runner: FakeSubprocessRunner(),
            fileExists: { $0.hasSuffix("health/supervisor.ready") },
            acceptProbe: { await probe.next() },
            clock: clock,
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
        #expect(probe.calls == 3)
    }

    @Test func probeAcceptThenMarkerReadyReturnsReady() async throws {
        let runtime = try makeRuntime()
        let clock = AdvancingReadinessClock()
        let probe = SequencedAcceptProbe([false, true])
        let gate = JournalReadinessGate(
            runner: FakeSubprocessRunner(),
            fileExists: { $0.hasSuffix("health/supervisor.ready") },
            acceptProbe: { await probe.next() },
            clock: clock,
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(5),
            terminalCheck: { nil }
        )

        #expect(result == .ready)
        #expect(probe.calls == 2)
    }

    @Test func probeAcceptAndHealthReadyReturnsReady() async throws {
        let runtime = try makeRuntime()
        let gate = JournalReadinessGate(
            runner: FakeSubprocessRunner(),
            fileExists: { _ in false },
            acceptProbe: { true },
            clock: AdvancingReadinessClock(),
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(5),
            terminalCheck: { nil }
        )

        #expect(result == .ready)
    }

    @Test func terminalCheckFailsImmediatelyBeforeDeadline() async throws {
        let runtime = try makeRuntime()
        let clock = AdvancingReadinessClock()
        let diagnostic = JournalDiagnostic(
            commandLabel: "journal start --app-supervised",
            outputExcerpt: UICopy.JOURNAL_CHILD_BREAKER_TRIPPED
        )
        let gate = JournalReadinessGate(
            runner: FakeSubprocessRunner(),
            fileExists: { _ in false },
            acceptProbe: { false },
            clock: clock,
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .seconds(120),
            terminalCheck: { diagnostic }
        )

        #expect(result == .failedTerminal(diagnostic))
        #expect(clock.now() == .zero)
    }

    @Test func slowAlivePathStillTimesOutAtDeadline() async throws {
        let runtime = try makeRuntime()
        let clock = AdvancingReadinessClock()
        let gate = JournalReadinessGate(
            runner: FakeSubprocessRunner(),
            fileExists: { _ in false },
            acceptProbe: { false },
            clock: clock,
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            timeout: .milliseconds(3),
            terminalCheck: { nil }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
        #expect(clock.now() == .milliseconds(3))
    }
}

private final class SequencedAcceptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]
    private var count = 0

    init(_ values: [Bool]) {
        self.values = values
    }

    var calls: Int {
        lock.withLock { count }
    }

    func next() async -> Bool {
        lock.withLock {
            count += 1
            guard !values.isEmpty else {
                return false
            }
            return values.removeFirst()
        }
    }
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
