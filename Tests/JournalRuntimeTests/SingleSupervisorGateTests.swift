// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("SingleSupervisorGate")
struct SingleSupervisorGateTests {
    @Test func sameRootRetirementBootsOutPollsUnlinksRefreshesThenSweeps() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try fixture.writePlist()
        let uid = getuid()

        fixture.runner.enqueue("launchctl", .success(
            stdout: Data(loadedPrint(path: fixture.plistURL.path, state: "running", pid: 111).utf8),
            sideEffect: { fixture.events.append("print-initial") }
        ))
        fixture.runner.enqueue("launchctl", .success(sideEffect: { fixture.events.append("bootout") }))
        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: {
            fixture.events.append(FileManager.default.fileExists(atPath: fixture.plistURL.path) ? "poll-before-unlink" : "poll-after-unlink")
        }))
        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: { fixture.events.append("print-refresh") }))
        fixture.runner.enqueue("ps", .success(
            stdout: Data("111 1 \(uid) journal: start\n".utf8),
            sideEffect: { fixture.events.append("ps") }
        ))
        fixture.enqueueFreePorts()

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        #expect(result == .success)
        #expect(fixture.launchctlSubcommands() == ["print", "bootout", "print", "print"])
        #expect(fixture.events.snapshot() == [
            "print-initial",
            "bootout",
            "poll-before-unlink",
            "print-refresh",
            "ps",
            "term:111:\(SIGTERM)",
            "lsof:7657",
            "lsof:5015"
        ])
        #expect(!FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    @Test func matchingPlistAndNotFoundUnlinksWithoutBootoutFailure() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try fixture.writePlist()

        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: { fixture.events.append("print-initial-113") }))
        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: { fixture.events.append("print-refresh") }))
        fixture.enqueueEmptyPs()
        fixture.enqueueFreePorts()

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        #expect(result == .success)
        #expect(fixture.launchctlSubcommands() == ["print", "print"])
        #expect(fixture.events.snapshot() == ["print-initial-113", "print-refresh", "ps", "lsof:7657", "lsof:5015"])
        #expect(!FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }

    @Test func differentRootBlocksWithZeroMutation() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try fixture.writePlist(standardOutRoot: fixture.tempHome.appendingPathComponent("other", isDirectory: true))
        let plistSnapshot = try fixture.readPlistData()

        fixture.runner.enqueue("launchctl", .success(
            stdout: Data(loadedPrint(path: fixture.plistURL.path, state: "running", pid: 111).utf8),
            sideEffect: { fixture.events.append("print-initial") }
        ))

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        expectBlockedWithZeroMutation(result, fixture: fixture, expectedEvents: ["print-initial"], plistSnapshot: plistSnapshot)
    }

    @Test func malformedPlistBlocksWithZeroMutation() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plistSnapshot = Data("not a plist".utf8)
        try plistSnapshot.write(to: fixture.plistURL)
        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: { fixture.events.append("print-initial") }))

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        expectBlockedWithZeroMutation(result, fixture: fixture, expectedEvents: ["print-initial"], plistSnapshot: plistSnapshot)
    }

    @Test func labelLoadedWithPlistAbsentBlocksWithZeroMutation() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        fixture.runner.enqueue("launchctl", .success(
            stdout: Data(loadedPrint(path: fixture.plistURL.path, state: "running", pid: 111).utf8),
            sideEffect: { fixture.events.append("print-initial") }
        ))

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        expectBlockedWithZeroMutation(result, fixture: fixture, expectedEvents: ["print-initial"], plistSnapshot: nil)
    }

    @Test func loadedJobDisagreementBlocksWithZeroMutation() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try fixture.writePlist()
        let plistSnapshot = try fixture.readPlistData()
        fixture.runner.enqueue("launchctl", .success(
            stdout: Data(mismatchedLoadedPrint(path: fixture.plistURL.path, pid: 111).utf8),
            sideEffect: { fixture.events.append("print-initial") }
        ))

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        expectBlockedWithZeroMutation(result, fixture: fixture, expectedEvents: ["print-initial"], plistSnapshot: plistSnapshot)
    }

    @Test func inspectionFailureBlocksWithZeroMutation() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try fixture.writePlist()
        let plistSnapshot = try fixture.readPlistData()
        fixture.runner.enqueue("launchctl", .success(exitCode: 5, sideEffect: { fixture.events.append("print-error") }))

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        expectBlockedWithZeroMutation(result, fixture: fixture, expectedEvents: ["print-error"], plistSnapshot: plistSnapshot)
    }

    @Test func bootoutFailureBlocksWithoutUnlink() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try fixture.writePlist()
        fixture.runner.enqueue("launchctl", .success(
            stdout: Data(loadedPrint(path: fixture.plistURL.path, state: "running", pid: 111).utf8),
            sideEffect: { fixture.events.append("print-initial") }
        ))
        fixture.runner.enqueue("launchctl", .success(exitCode: 4, sideEffect: { fixture.events.append("bootout-failed") }))

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        expectBlocked(result)
        #expect(fixture.events.snapshot() == ["print-initial", "bootout-failed"])
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(fixture.terminations.snapshot().isEmpty)
    }

    @Test func unloadTimeoutBlocksWithoutUnlink() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try fixture.writePlist()
        fixture.runner.enqueue("launchctl", .success(
            stdout: Data(loadedPrint(path: fixture.plistURL.path, state: "running", pid: 111).utf8),
            sideEffect: { fixture.events.append("print-initial") }
        ))
        fixture.runner.enqueue("launchctl", .success(sideEffect: { fixture.events.append("bootout") }))
        for _ in 0..<25 {
            fixture.runner.enqueue("launchctl", .success(
                stdout: Data(loadedPrint(path: fixture.plistURL.path, state: "running", pid: 111).utf8),
                sideEffect: { fixture.events.append("poll-loaded") }
            ))
        }

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        expectBlocked(result)
        #expect(Array(fixture.events.snapshot().prefix(2)) == ["print-initial", "bootout"])
        #expect(fixture.events.snapshot().contains("poll-loaded"))
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(fixture.terminations.snapshot().isEmpty)
    }

    @Test func unlinkFailureBlocksAfterSuccessfulUnload() async throws {
        let fixture = try GateFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.plistURL.deletingLastPathComponent().path)
            fixture.cleanup()
        }
        try fixture.writePlist()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.plistURL.deletingLastPathComponent().path)
        fixture.runner.enqueue("launchctl", .success(stdout: Data(loadedPrint(path: fixture.plistURL.path, state: "running", pid: 111).utf8)))
        fixture.runner.enqueue("launchctl", .success())
        fixture.runner.enqueue("launchctl", .success(exitCode: 113))

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        expectBlocked(result)
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(fixture.terminations.snapshot().isEmpty)
    }

    @Test func cancellationBeforeRetirementMutationBlocksWithoutBootoutOrUnlink() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try fixture.writePlist()
        fixture.runner.enqueue("launchctl", .success(
            stdout: Data(loadedPrint(path: fixture.plistURL.path, state: "running", pid: 111).utf8),
            delay: .seconds(60),
            sideEffect: { fixture.events.append("print-initial") }
        ))
        fixture.runner.enqueue("launchctl", .success(sideEffect: { fixture.events.append("bootout") }))

        let task = Task {
            await fixture.gate().prepareForSpawn(
                journalRoot: fixture.journalRoot,
                context: LaunchAuthorizationContext()
            )
        }
        await Task.yield()
        task.cancel()
        let result = await task.value

        expectBlocked(result)
        #expect(!fixture.events.snapshot().contains("bootout"))
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(fixture.terminations.snapshot().isEmpty)
    }

    @Test func cancellationDuringRefreshReportsCancelledNotRetirementFailure() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: { fixture.events.append("print-initial") }))
        fixture.runner.enqueue("launchctl", .success(
            exitCode: 113,
            delay: .seconds(60),
            sideEffect: { fixture.events.append("print-refresh") }
        ))

        let task = Task {
            await fixture.gate().prepareForSpawn(
                journalRoot: fixture.journalRoot,
                context: LaunchAuthorizationContext()
            )
        }
        await waitForInvocationCount(fixture.runner, 2)
        task.cancel()
        let result = await task.value

        guard case .blocked(let blockage) = result else {
            Issue.record("expected cancellation blockage, got \(result)")
            return
        }
        #expect(fixture.launchctlSubcommands() == ["print", "print"])
        #expect(blockage.ownerMessage == UICopy.JOURNAL_SPAWN_CANCELLED)
        #expect(blockage.ownerMessage != UICopy.JOURNAL_SPAWN_LEGACY_SERVICE_RETIRE_FAILED)
        #expect(fixture.terminations.snapshot().isEmpty)
    }

    @Test func noOrphansSkipGraceSleepBeforePortChecks() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: { fixture.events.append("print-initial-113") }))
        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: { fixture.events.append("print-refresh") }))
        fixture.enqueueEmptyPs()
        fixture.enqueueFreePorts()

        let result = await fixture.gate(orphanGracePeriod: .seconds(3)).prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        #expect(result == .success)
        #expect(fixture.clock.sleepCount() == 0)
        #expect(fixture.events.snapshot() == ["print-initial-113", "print-refresh", "ps", "lsof:7657", "lsof:5015"])
    }

    @Test func loadedNotRunningStillRequiresBootout() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanup() }
        try fixture.writePlist()
        fixture.runner.enqueue("launchctl", .success(
            stdout: Data(loadedPrint(path: fixture.plistURL.path, state: "not running", pid: nil).utf8),
            sideEffect: { fixture.events.append("print-not-running") }
        ))
        fixture.runner.enqueue("launchctl", .success(sideEffect: { fixture.events.append("bootout") }))
        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: { fixture.events.append("poll-113") }))
        fixture.runner.enqueue("launchctl", .success(exitCode: 113, sideEffect: { fixture.events.append("print-refresh") }))
        fixture.enqueueEmptyPs()
        fixture.enqueueFreePorts()

        let result = await fixture.gate().prepareForSpawn(
            journalRoot: fixture.journalRoot,
            context: LaunchAuthorizationContext()
        )

        #expect(result == .success)
        #expect(Array(fixture.events.snapshot().prefix(3)) == ["print-not-running", "bootout", "poll-113"])
        #expect(!FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }
}

private struct Termination: Equatable, Sendable {
    let pid: pid_t
    let signal: Int32
}

private final class GateFixture: @unchecked Sendable {
    let tempHome: URL
    let journalRoot: URL
    let label: String
    let plistURL: URL
    let runner = FakeSubprocessRunner()
    let events = StringEventRecorder()
    let terminations = TerminationRecorder()
    let clock = ImmediateClock()

    init() throws {
        tempHome = try makeTemporaryDirectory()
        journalRoot = tempHome.appendingPathComponent("journal", isDirectory: true)
        label = "com.example.solstone-test-\(UUID().uuidString)"
        plistURL = tempHome
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    func gate(orphanGracePeriod: Duration = .zero) -> SingleSupervisorGate {
        SingleSupervisorGate(
            runner: runner,
            pidExists: { _ in false },
            terminate: { [terminations, events] pid, signal in
                terminations.append(pid: pid, signal: signal)
                events.append("term:\(pid):\(signal)")
                return 0
            },
            environmentReader: { [journalRoot] pid in
                pid == 111 ? ["SOLSTONE_JOURNAL": journalRoot.path] : nil
            },
            clock: clock,
            orphanGracePeriod: orphanGracePeriod,
            homeDirectory: tempHome,
            launchdLabel: label,
            launchdPlistURL: plistURL
        )
    }

    func writePlist(standardOutRoot: URL? = nil) throws {
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let serviceRoot = standardOutRoot ?? journalRoot
        let serviceLog = serviceRoot
            .appendingPathComponent("health", isDirectory: true)
            .appendingPathComponent("service.log")
            .path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/Users/jer/.local/bin/journal", "start", "5015"],
            "StandardOutPath": serviceLog,
            "StandardErrorPath": serviceLog,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
    }

    func readPlistData() throws -> Data {
        try Data(contentsOf: plistURL)
    }

    func launchctlSubcommands() -> [String] {
        runner.invocations
            .filter { $0.executable.lastPathComponent == "launchctl" }
            .compactMap { $0.arguments.first }
    }

    func enqueueEmptyPs() {
        runner.enqueue("ps", .success(sideEffect: { [events] in events.append("ps") }))
    }

    func enqueueFreePorts() {
        runner.enqueueLsof(port: 7657, .success(exitCode: 1, sideEffect: { [events] in events.append("lsof:7657") }))
        runner.enqueueLsof(port: 5015, .success(exitCode: 1, sideEffect: { [events] in events.append("lsof:5015") }))
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: plistURL.deletingLastPathComponent().path)
        try? FileManager.default.removeItem(at: tempHome)
    }
}

private final class StringEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock {
            values.append(value)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { values }
    }
}

private final class TerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Termination] = []

    func append(pid: pid_t, signal: Int32) {
        lock.withLock {
            values.append(Termination(pid: pid, signal: signal))
        }
    }

    func snapshot() -> [Termination] {
        lock.withLock { values }
    }
}

private final class ImmediateClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    private var sleeps = 0

    func now() -> Duration {
        lock.withLock { value }
    }

    func sleep(for duration: Duration) async {
        lock.withLock {
            sleeps += 1
            value += duration
        }
        await Task.yield()
    }

    func sleepCount() -> Int {
        lock.withLock { sleeps }
    }
}

private func expectBlocked(_ result: SingleSupervisorGateResult) {
    guard case .blocked = result else {
        Issue.record("expected blocked gate result, got \(result)")
        return
    }
}

private func expectBlockedWithZeroMutation(
    _ result: SingleSupervisorGateResult,
    fixture: GateFixture,
    expectedEvents: [String],
    plistSnapshot: Data?
) {
    expectBlocked(result)
    #expect(fixture.events.snapshot() == expectedEvents)
    #expect(fixture.launchctlSubcommands().allSatisfy { $0 == "print" })
    #expect(!fixture.launchctlSubcommands().contains("bootout"))
    if let plistSnapshot {
        #expect((try? fixture.readPlistData()) == plistSnapshot)
    } else {
        #expect(!FileManager.default.fileExists(atPath: fixture.plistURL.path))
    }
    #expect(fixture.terminations.snapshot().isEmpty)
    #expect(!fixture.runner.invocations.contains { invocation in
        invocation.executable.lastPathComponent == "journal" && invocation.arguments.first == "start"
    })
}

private func waitForInvocationCount(_ runner: FakeSubprocessRunner, _ count: Int) async {
    for _ in 0..<1_000 {
        if runner.invocations.count >= count {
            return
        }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(count) subprocess invocations")
}

private func loadedPrint(path: String, state: String, pid: pid_t?) -> String {
    let pidLine = pid.map { "pid = \($0)\n" } ?? ""
    return """
    path = \(path)
    state = \(state)
    program = /Users/jer/.local/bin/journal
    arguments = {
        /Users/jer/.local/bin/journal
        start
        5015
    }
    \(pidLine)properties = inferred program
    """
}

private func mismatchedLoadedPrint(path: String, pid: pid_t) -> String {
    """
    path = \(path)
    state = running
    program = /bin/sleep
    arguments = {
        /bin/sleep
        30
    }
    pid = \(pid)
    properties = inferred program
    """
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("single-supervisor-gate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
