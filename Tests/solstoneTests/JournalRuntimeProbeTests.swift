// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("Journal runtime probe")
@MainActor
struct JournalRuntimeProbeTests {
    private let journalBinary = URL(fileURLWithPath: "/runtime/bin/journal")

    @Test func debounceThreeFailuresUnderTenSecondsDoesNotTrip() {
        var state = JournalRuntimeDebounceState()
        let start = Date(timeIntervalSince1970: 100)

        #expect(state.apply(outcome: .unreachable(diag("one")), now: start, currentStatus: .running) == .running)
        #expect(state.apply(outcome: .unreachable(diag("two")), now: start.addingTimeInterval(4), currentStatus: .running) == .running)
        #expect(state.apply(outcome: .unreachable(diag("three")), now: start.addingTimeInterval(9), currentStatus: .running) == .running)
    }

    @Test func debounceUnreachableTripsStoppedAfterThreeFailuresSpanningTenSeconds() {
        var state = JournalRuntimeDebounceState()
        let start = Date(timeIntervalSince1970: 100)
        let latest = diag("latest")

        _ = state.apply(outcome: .unreachable(diag("one")), now: start, currentStatus: .running)
        _ = state.apply(outcome: .unreachable(diag("two")), now: start.addingTimeInterval(5), currentStatus: .running)
        let result = state.apply(outcome: .unreachable(latest), now: start.addingTimeInterval(10), currentStatus: .running)

        #expect(result == .stopped(latest))
    }

    @Test func debounceUnknownTripsUnknownAfterThreeFailuresSpanningTenSeconds() {
        var state = JournalRuntimeDebounceState()
        let start = Date(timeIntervalSince1970: 100)
        let latest = diag("timeout", timedOut: true)

        _ = state.apply(outcome: .unknown(diag("one")), now: start, currentStatus: .running)
        _ = state.apply(outcome: .unknown(diag("two")), now: start.addingTimeInterval(5), currentStatus: .running)
        let result = state.apply(outcome: .unknown(latest), now: start.addingTimeInterval(10), currentStatus: .running)

        #expect(result == .unknown(latest))
    }

    @Test func reachableClearsAttentionImmediately() {
        var state = JournalRuntimeDebounceState()

        let result = state.apply(
            outcome: .reachable,
            now: Date(timeIntervalSince1970: 100),
            currentStatus: .stopped(diag("down"))
        )

        #expect(result == .running)
    }

    @Test func binaryMissingSetsSetupNeededImmediately() {
        var state = JournalRuntimeDebounceState()

        let result = state.apply(
            outcome: .binaryMissing,
            now: Date(timeIntervalSince1970: 100),
            currentStatus: .stopped(diag("down"))
        )

        #expect(result == .setupNeeded)
    }

    @Test func probeReturnsBinaryMissingWithoutRunningWhenJournalMissing() async {
        let runner = FakeSubprocessRunner()

        let outcome = await JournalRuntimeProbe.run(
            journalBinary: journalBinary,
            runner: runner,
            fileExists: { _ in false }
        )

        #expect(outcome == .binaryMissing)
        #expect(runner.invocations.isEmpty)
    }

    @Test func probeMapsJournalHealthResult() async {
        let healthyRunner = FakeSubprocessRunner()
        healthyRunner.enqueue("health", .success())
        let healthy = await JournalRuntimeProbe.run(
            journalBinary: journalBinary,
            runner: healthyRunner,
            fileExists: { _ in true }
        )

        let stoppedRunner = FakeSubprocessRunner()
        stoppedRunner.enqueue("health", .success(stderr: Data("not ready\n".utf8), exitCode: 1))
        let stopped = await JournalRuntimeProbe.run(
            journalBinary: journalBinary,
            runner: stoppedRunner,
            fileExists: { _ in true }
        )

        #expect(healthy == .reachable)
        guard case .unreachable(let diagnostic) = stopped else {
            Issue.record("expected unreachable, got \(stopped)")
            return
        }
        #expect(diagnostic.exitCode == 1)
        #expect(healthyRunner.invocations.first?.executable.lastPathComponent == "journal")
        #expect(stoppedRunner.invocations.first?.executable.lastPathComponent == "journal")
    }

    @Test func orphanSweepKillsOnlyPpidOneJournalProcesses() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("ps", .success(stdout: Data("""
          PID  PPID COMM
          111     1 journal:supervisor
          222     2 journal:worker
          333     1 bash
          444     1 sol:service
          555     1 journal:service
          666     1 journal: foo bar
         -777     1 journal:negative-pid
          888    -1 journal:negative-ppid
          not-a-pid 1 journal:bad
        """.utf8)))
        runner.enqueue("service", .success())
        let terminated = LockedPIDRecorder()
        let restart = JournalRestartRunner(
            runner: runner,
            journalPathProvider: { _ in temp.path },
            terminate: { pid in terminated.append(pid) },
            reprobe: { .reachable },
            journalBinary: journalBinary
        )

        let outcome = await restart.run()

        #expect(outcome == .success)
        #expect(terminated.values == [111, 555, 666])
    }

    @Test func staleStateMoveAsideSkipsMissingAndOverwritesBak() throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let health = temp.appendingPathComponent("health")
        try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
        let pid = health.appendingPathComponent("supervisor.pid")
        let pidBackup = URL(fileURLWithPath: pid.path + ".bak")
        try Data("new".utf8).write(to: pid)
        try Data("old".utf8).write(to: pidBackup)

        let events = moveAsideStaleStateFiles(journalRoot: temp)

        #expect(events.count == staleStateRelativePaths.count)
        #expect(!FileManager.default.fileExists(atPath: pid.path))
        #expect((try String(contentsOf: pidBackup, encoding: .utf8)) == "new")
        #expect(events.contains { $0.detail == "health/supervisor.pid:moved" })
        #expect(events.contains { $0.detail == "health/supervisor.ready:missing" })
    }

    @Test func restartSuccessLogsAllStepsAndRestoresError() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.errorMessage = "existing"
        state.journalBinaryProvider = { journalBinary }
        state.journalRuntimeFileExists = { _ in true }
        let events = LockedEventRecorder()
        state.journalRestartLogSink = { event in events.append(event) }
        state.journalRestartRunnerFactory = { journalBinary, logSink in
            let runner = FakeSubprocessRunner()
            runner.enqueue("ps", .success(stdout: Data()))
            runner.enqueue("service", .success())
            return JournalRestartRunner(
                runner: runner,
                journalPathProvider: { _ in temp.path },
                terminate: { _ in },
                reprobe: { .reachable },
                logSink: logSink,
                journalBinary: journalBinary
            )
        }

        state.requestJournalRestart()
        try await waitUntil {
            events.values.contains { $0.step == .reProbe } && !state.journalRuntimeStatus.isRestarting
        }

        #expect(state.errorMessage == "existing")
        #expect(state.journalRuntimeStatus == .running)
        #expect(stepCounts(events.values) == Dictionary(uniqueKeysWithValues: JournalRestartStep.allCases.map { ($0, 1) }))
    }

    @Test func restartReprobeFailureAfterCommandSuccessFailsImmediately() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.journalBinaryProvider = { journalBinary }
        state.journalRuntimeFileExists = { _ in true }
        let postRestart = diag("post restart")
        state.journalRestartRunnerFactory = { journalBinary, logSink in
            let runner = FakeSubprocessRunner()
            runner.enqueue("ps", .success(stdout: Data()))
            runner.enqueue("service", .success())
            return JournalRestartRunner(
                runner: runner,
                journalPathProvider: { _ in temp.path },
                terminate: { _ in },
                reprobe: { .unreachable(postRestart) },
                logSink: logSink,
                journalBinary: journalBinary
            )
        }

        state.requestJournalRestart()
        try await waitUntil {
            state.errorMessage == "restart failed — journal did not come back"
        }

        #expect(state.journalRuntimeStatus == .stopped(diag("post restart")))
    }

    @Test func restartResolveJournalFailureHaltsBeforeSideEffects() async {
        let runner = FakeSubprocessRunner()
        let terminated = LockedPIDRecorder()
        let events = LockedEventRecorder()
        let restart = JournalRestartRunner(
            runner: runner,
            journalPathProvider: { _ in nil },
            terminate: { pid in terminated.append(pid) },
            reprobe: { .reachable },
            logSink: { event in events.append(event) },
            journalBinary: journalBinary
        )

        let outcome = await restart.run()

        guard case .failure(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.step == .resolveJournal)
        #expect(failure.ownerMessage == "restart failed — journal path could not be read")
        #expect(runner.invocations.isEmpty)
        #expect(terminated.values.isEmpty)
        #expect(events.values == [
            JournalRestartLogEvent(step: .resolveJournal, outcome: "error", detail: "no-journal-path")
        ])
    }

    @Test func externalModeTransitionClearsJournalStatusAndStopsTimer() {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.journalRuntimeStatus = .stopped(diag("down"))

        state.updateConfig(AppConfig(serviceMode: .external))

        #expect(state.journalRuntimeStatus == .running)
    }

    @Test func notifyUpgradeStartedClearsJournalProbeState() {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.journalRuntimeStatus = .stopped(diag("down"))

        state.notifyUpgradeStarted()

        #expect(state.journalRuntimeStatus == .running)
    }

    @Test func journalProbeTickReturnsEarlyDuringUpgrade() async {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.installer.upgradeInProgress = true
        state.journalRuntimeStatus = .stopped(diag("down"))
        let runner = FakeSubprocessRunner()
        state.journalRuntimeProbeRunner = runner
        state.journalRuntimeFileExists = { _ in true }

        await state.journalProbeTick()

        #expect(state.journalRuntimeStatus == .stopped(diag("down")))
        #expect(runner.invocations.isEmpty)
    }

    @Test func externalModeRunsNoLocalJournalActionsForProbeOrRestart() async {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .external))
        let runner = FakeSubprocessRunner()
        state.journalRuntimeProbeRunner = runner
        state.journalRuntimeFileExists = { _ in true }

        await state.journalProbeTick()
        state.requestJournalRestart()

        #expect(runner.invocations.isEmpty)
    }

    @Test func journalSurfaceAvailabilityRequiresInstalledBundledState() {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .detecting
        state.journalRuntimeStatus = .setupNeeded

        #expect(!state.bundledJournalStatusAvailable)
        #expect(!state.bundledJournalRestartAvailable)

        state.installer.main = .done

        #expect(state.bundledJournalStatusAvailable)
        #expect(!state.bundledJournalRestartAvailable)

        state.journalRuntimeStatus = .running

        #expect(state.bundledJournalRestartAvailable)

        state.updateConfig(AppConfig(serviceMode: .external))

        #expect(!state.bundledJournalStatusAvailable)
        #expect(!state.bundledJournalRestartAvailable)
    }

    private func diag(_ text: String, timedOut: Bool = false) -> JournalDiagnostic {
        JournalDiagnostic(commandLabel: "journal health", timedOut: timedOut, outputExcerpt: text)
    }

    private func stepCounts(_ events: [JournalRestartLogEvent]) -> [JournalRestartStep: Int] {
        Dictionary(grouping: events, by: \.step).mapValues(\.count)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(predicate())
    }
}

private final class LockedPIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [pid_t] = []

    var values: [pid_t] {
        lock.withLock { pids }
    }

    func append(_ pid: pid_t) {
        lock.withLock {
            pids.append(pid)
        }
    }
}

private final class LockedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [JournalRestartLogEvent] = []

    var values: [JournalRestartLogEvent] {
        lock.withLock { events }
    }

    func append(_ event: JournalRestartLogEvent) {
        lock.withLock {
            events.append(event)
        }
    }
}
