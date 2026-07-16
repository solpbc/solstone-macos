// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin
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
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let files = readinessFiles(root: runtime.layout.rootURL, child: child)
        let gate = JournalReadinessGate(
            readTextFile: { files[$0] },
            processStartTime: { $0 == child.pid ? child.startTime : nil },
            acceptProbe: { await probe.next() },
            clock: clock,
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(3),
            generationIsCurrent: { $0 == child.generation },
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
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let files = readinessFiles(root: runtime.layout.rootURL, child: child)
        let gate = JournalReadinessGate(
            readTextFile: { files[$0] },
            processStartTime: { $0 == child.pid ? child.startTime : nil },
            acceptProbe: { await probe.next() },
            clock: clock,
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(5),
            generationIsCurrent: { $0 == child.generation },
            terminalCheck: { nil }
        )

        #expect(result == .ready)
        #expect(probe.calls == 2)
    }

    @Test func probeAcceptWithoutValidMarkerTimesOut() async throws {
        let runtime = try makeRuntime()
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let gate = JournalReadinessGate(
            readTextFile: { _ in nil },
            processStartTime: { $0 == child.pid ? child.startTime : nil },
            acceptProbe: { true },
            clock: AdvancingReadinessClock(),
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(5),
            generationIsCurrent: { $0 == child.generation },
            terminalCheck: { nil }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
    }

    @Test func terminalCheckFailsImmediatelyBeforeDeadline() async throws {
        let runtime = try makeRuntime()
        let clock = AdvancingReadinessClock()
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let diagnostic = JournalDiagnostic(
            commandLabel: "journal start --app-supervised",
            outputExcerpt: UICopy.JOURNAL_CHILD_BREAKER_TRIPPED
        )
        let gate = JournalReadinessGate(
            readTextFile: { _ in nil },
            processStartTime: { $0 == child.pid ? child.startTime : nil },
            acceptProbe: { false },
            clock: clock,
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .seconds(120),
            generationIsCurrent: { $0 == child.generation },
            terminalCheck: { diagnostic }
        )

        #expect(result == .failedTerminal(diagnostic))
        #expect(clock.now() == .zero)
    }

    @Test func slowAlivePathStillTimesOutAtDeadline() async throws {
        let runtime = try makeRuntime()
        let clock = AdvancingReadinessClock()
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let gate = JournalReadinessGate(
            readTextFile: { _ in nil },
            processStartTime: { $0 == child.pid ? child.startTime : nil },
            acceptProbe: { false },
            clock: clock,
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(3),
            generationIsCurrent: { $0 == child.generation },
            terminalCheck: { nil }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected readiness timeout, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
        #expect(clock.now() == .milliseconds(3))
    }

    @Test func staleMarkerPIDNeverReadies() async throws {
        let runtime = try makeRuntime()
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let files = readinessFiles(root: runtime.layout.rootURL, child: child, markerPID: 999, pidFilePID: 999)
        let gate = JournalReadinessGate(
            readTextFile: { files[$0] },
            processStartTime: { $0 == 999 ? 100 : child.startTime },
            acceptProbe: { true },
            clock: AdvancingReadinessClock(),
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(3),
            generationIsCurrent: { $0 == child.generation },
            terminalCheck: { nil }
        )

        expectNotReady(result)
    }

    @Test func staleMarkerStartTimeNeverReadies() async throws {
        let runtime = try makeRuntime()
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let files = readinessFiles(root: runtime.layout.rootURL, child: child, markerStartTime: 102)
        let gate = JournalReadinessGate(
            readTextFile: { files[$0] },
            processStartTime: { $0 == child.pid ? child.startTime : nil },
            acceptProbe: { true },
            clock: AdvancingReadinessClock(),
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(3),
            generationIsCurrent: { $0 == child.generation },
            terminalCheck: { nil }
        )

        expectNotReady(result)
    }

    @Test func markerPIDMismatchWithSupervisorPIDFileNeverReadies() async throws {
        let runtime = try makeRuntime()
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let files = readinessFiles(root: runtime.layout.rootURL, child: child, markerPID: 4242, pidFilePID: 999)
        let gate = JournalReadinessGate(
            readTextFile: { files[$0] },
            processStartTime: { $0 == child.pid ? child.startTime : nil },
            acceptProbe: { true },
            clock: AdvancingReadinessClock(),
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(3),
            generationIsCurrent: { $0 == child.generation },
            terminalCheck: { nil }
        )

        expectNotReady(result)
    }

    @Test func childExitBeforeFinalRecheckNeverReadies() async throws {
        let runtime = try makeRuntime()
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let files = readinessFiles(root: runtime.layout.rootURL, child: child)
        let startTimes = SequencedStartTimes([child.startTime, nil, nil, nil])
        let gate = JournalReadinessGate(
            readTextFile: { files[$0] },
            processStartTime: { _ in startTimes.next() },
            acceptProbe: { true },
            clock: AdvancingReadinessClock(),
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(3),
            generationIsCurrent: { $0 == child.generation },
            terminalCheck: { nil }
        )

        expectNotReady(result)
    }

    @Test func staleGenerationAtReadinessNeverReadies() async throws {
        let runtime = try makeRuntime()
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let files = readinessFiles(root: runtime.layout.rootURL, child: child)
        let gate = JournalReadinessGate(
            readTextFile: { files[$0] },
            processStartTime: { $0 == child.pid ? child.startTime : nil },
            acceptProbe: { true },
            clock: AdvancingReadinessClock(),
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(3),
            generationIsCurrent: { _ in false },
            terminalCheck: { nil }
        )

        expectNotReady(result)
    }

    @Test func realStaleStateWithoutReadyMarkerTimesOut() async throws {
        let runtime = try makeRuntime()
        let child = JournalChildIdentity(pid: 4242, startTime: 100, generation: 7)
        let pidPath = runtime.layout.rootURL.appendingPathComponent("health/supervisor.pid").path
        let startTimePath = runtime.layout.rootURL.appendingPathComponent("health/supervisor.start_time").path
        let files = [
            pidPath: "30493\n",
            startTimePath: "1783004521.665381\n"
        ]
        let gate = JournalReadinessGate(
            readTextFile: { files[$0] },
            processStartTime: { $0 == child.pid ? child.startTime : nil },
            acceptProbe: { true },
            clock: AdvancingReadinessClock(),
            pollInterval: .milliseconds(1)
        )

        let result = await gate.waitUntilReady(
            journalRoot: runtime.layout.rootURL,
            runtime: runtime,
            child: child,
            timeout: .milliseconds(3),
            generationIsCurrent: { $0 == child.generation },
            terminalCheck: { nil }
        )

        guard case .failed(let diagnostic) = result else {
            Issue.record("expected failed stale-state readiness, got \(result)")
            return
        }
        #expect(diagnostic.timedOut)
    }
}

private func readinessFiles(
    root: URL,
    child: JournalChildIdentity,
    markerPID: pid_t? = nil,
    pidFilePID: pid_t? = nil,
    markerStartTime: TimeInterval? = nil
) -> [String: String] {
    let ready = root.appendingPathComponent("health/supervisor.ready").path
    let pid = root.appendingPathComponent("health/supervisor.pid").path
    let markerPID = markerPID ?? child.pid
    let pidFilePID = pidFilePID ?? child.pid
    let markerStartTime = markerStartTime ?? child.startTime
    return [
        ready: #"{"pid":\#(markerPID),"ready_at":101.0,"start_time":\#(markerStartTime)}"#,
        pid: "\(pidFilePID)\n"
    ]
}

private func expectNotReady(_ result: JournalReadinessResult) {
    guard case .failed = result else {
        Issue.record("expected failed readiness, got \(result)")
        return
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

private final class SequencedStartTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval?]

    init(_ values: [TimeInterval?]) {
        self.values = values
    }

    func next() -> TimeInterval? {
        lock.withLock {
            values.isEmpty ? nil : values.removeFirst()
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
