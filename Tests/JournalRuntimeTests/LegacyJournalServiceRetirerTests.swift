// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("LegacyJournalServiceRetirer")
struct LegacyJournalServiceRetirerTests {
    @Test func sameRootLoadedServiceBootsOutPollsAbsentAndUnlinks() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stdout: Data(loadedLaunchctlOutput(plistPath: fixture.plistURL.path).utf8)))
        runner.enqueue("bootout", .success())
        runner.enqueue("print", .success(stderr: Data(notFoundLaunchctlError.utf8), exitCode: 113))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        #expect(result == .success(.provenMatchLoaded))
        #expect(!FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(runner.invocations.map(\.arguments.first) == ["print", "bootout", "print"])
    }

    @Test func noServiceRequiresNotFoundMarkerNotExitCodeAlone() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stderr: Data("launchctl failed\n".utf8), exitCode: 113))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, let diagnostic) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(diagnostic.commandLabel == "legacy journal service")
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func launchctlThrowBlocksWithoutBootoutOrUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .failure("launchctl failed"))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, _) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func launchctlTimeoutBlocksWithoutBootoutOrUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(delay: .milliseconds(1)))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501,
            commandTimeout: .milliseconds(1)
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, _) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func launchctlNonNotFoundNonzeroBlocksWithoutBootoutOrUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stderr: Data("launchctl failed\n".utf8), exitCode: 113))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, _) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func malformedLoadedLaunchctlBlocksWithoutBootoutOrUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stdout: Data("""
        gui/501/org.solpbc.solstone = {
            path = \(fixture.plistURL.path)
            state = running
        }

        """.utf8)))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, _) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func loadedButNotRunningStillRetiresOnSameRootMatch() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stdout: Data("""
        gui/501/org.solpbc.solstone = {
        \tpath = \(fixture.plistURL.path)
        \ttype = LaunchAgent
        \tstate = not running
        \tprogram = /Users/jer/.local/bin/journal
        \targuments = {
        \t\t/Users/jer/.local/bin/journal
        \t\tstart
        \t\t5015
        \t}
        }

        """.utf8)))
        runner.enqueue("bootout", .success())
        runner.enqueue("print", .success(stderr: Data(notFoundLaunchctlError.utf8), exitCode: 113))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        #expect(result == .success(.provenMatchLoaded))
        #expect(!FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(runner.invocations.map(\.arguments.first) == ["print", "bootout", "print"])
    }

    @Test func notLoadedSameRootPlistIsUnlinked() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stderr: Data(notFoundLaunchctlError.utf8), exitCode: 113))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        #expect(result == .success(.provenMatchUnloaded))
        #expect(!FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func differentRootBlocksWithoutMutation() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writePlist(replacing: ["/Users/jer/journal": "/Users/jer/other journal"])
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stderr: Data(notFoundLaunchctlError.utf8), exitCode: 113))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.differentRoot, _) = result else {
            Issue.record("expected different-root block, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func malformedPlistBlocksWithoutMutation() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writePlist(replacing: [
            "<key>StandardErrorPath</key>\n\t<string>/Users/jer/journal/health/service.log</string>":
                "<key>StandardErrorPath</key>\n\t<string>/Users/jer/journal/health/other.log</string>"
        ])
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stderr: Data(notFoundLaunchctlError.utf8), exitCode: 113))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.malformed, _) = result else {
            Issue.record("expected malformed block, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func missingRequiredPlistKeyBlocksWithoutBootoutOrUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writePlist(replacing: [
            "\t<key>StandardOutPath</key>\n\t<string>/Users/jer/journal/health/service.log</string>\n": ""
        ])
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stderr: Data(notFoundLaunchctlError.utf8), exitCode: 113))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.malformed, _) = result else {
            Issue.record("expected malformed block, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func labelWithoutPlistBlocksWithoutBootout() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stdout: Data(loadedLaunchctlOutput(plistPath: fixture.plistURL.path).utf8)))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.labelWithoutPlist, _) = result else {
            Issue.record("expected label-without-plist block, got \(result)")
            return
        }
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func plistVsJobDisagreementBlocksWithoutBootoutOrUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stdout: Data(loadedLaunchctlOutput(plistPath: fixture.root.appendingPathComponent("other.plist").path).utf8)))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.plistVsJobDisagreement, _) = result else {
            Issue.record("expected plist/job disagreement, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func bootoutNonzeroBlocksWithoutUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stdout: Data(loadedLaunchctlOutput(plistPath: fixture.plistURL.path).utf8)))
        runner.enqueue("bootout", .success(stderr: Data("bootout failed\n".utf8), exitCode: 5))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, _) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(runner.invocations.map(\.arguments.first) == ["print", "bootout"])
    }

    @Test func bootoutTimeoutBlocksWithoutUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stdout: Data(loadedLaunchctlOutput(plistPath: fixture.plistURL.path).utf8)))
        runner.enqueue("bootout", .success(delay: .milliseconds(1)))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501,
            commandTimeout: .milliseconds(1)
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, _) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(runner.invocations.map(\.arguments.first) == ["print", "bootout"])
    }

    @Test func absencePollTimeoutBlocksWithoutUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        let loaded = Data(loadedLaunchctlOutput(plistPath: fixture.plistURL.path).utf8)
        runner.enqueue("print", .success(stdout: loaded))
        runner.enqueue("bootout", .success())
        runner.enqueue("print", .success(stdout: loaded))
        runner.enqueue("print", .success(stdout: loaded))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501,
            absenceTimeout: .milliseconds(1),
            absencePollInterval: .milliseconds(1)
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, _) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(runner.invocations.map(\.arguments.first) == ["print", "bootout", "print", "print"])
    }

    @Test func unlinkFailureBlocksAfterProofWithoutRemovingPlist() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = FakeSubprocessRunner()
        runner.enqueue("print", .success(stderr: Data(notFoundLaunchctlError.utf8), exitCode: 113))
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501,
            fileManager: RemovalFailingLegacyFileManager(failingName: fixture.plistURL.lastPathComponent)
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, _) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(!runner.invocations.contains { $0.arguments.first == "bootout" })
    }

    @Test func cancellationDuringBootoutBlocksWithoutUnlink() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clear() }
        try fixture.writeSameRootPlist()
        let runner = BootoutCancellingLegacyRunner(
            loadedOutput: Data(loadedLaunchctlOutput(plistPath: fixture.plistURL.path).utf8)
        )
        let retirer = LegacyJournalServiceRetirer(
            runner: runner,
            clock: NoopLegacyClock(),
            plistURL: fixture.plistURL,
            uid: 501
        )

        let result = await retirer.retireLegacyService(journalRoot: fixture.sameRoot)

        guard case .blocked(.inspectionFailure, _) = result else {
            Issue.record("expected inspection failure, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.plistURL.path))
        #expect(runner.invocations.map(\.arguments.first) == ["print", "bootout"])
    }
}

private let notFoundLaunchctlError = """
Bad request.
Could not find service "org.solpbc.solstone" in domain for user gui: 501

"""

private func loadedLaunchctlOutput(plistPath: String, pid: pid_t = 777) -> String {
    """
gui/501/org.solpbc.solstone = {
    path = \(plistPath)
    state = running
    program = /Users/jer/.local/bin/journal
    arguments = {
        /Users/jer/.local/bin/journal
        start
        5015
    }
    pid = \(pid)
}

"""
}

private struct ServiceFixture {
    let root: URL
    let plistURL: URL
    let sameRoot = URL(fileURLWithPath: "/Users/jer/journal", isDirectory: true)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-service-retirer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        plistURL = root.appendingPathComponent("org.solpbc.solstone.plist")
    }

    func writeSameRootPlist() throws {
        try writePlist(replacing: [:])
    }

    func writePlist(replacing replacements: [String: String]) throws {
        let sourceURL = try #require(Bundle.module.url(
            forResource: "org.solpbc.solstone.same-root",
            withExtension: "plist",
            subdirectory: "Fixtures/legacy-service"
        ))
        var text = try String(contentsOf: sourceURL, encoding: .utf8)
        for (needle, replacement) in replacements {
            text = text.replacingOccurrences(of: needle, with: replacement)
        }
        try Data(text.utf8).write(to: plistURL)
    }

    func clear() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class NoopLegacyClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero

    func now() -> Duration {
        lock.withLock { value }
    }

    func sleep(for duration: Duration) async {
        lock.withLock { value += duration }
    }
}

private final class RemovalFailingLegacyFileManager: FileManager {
    private let failingName: String

    init(failingName: String) {
        self.failingName = failingName
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == failingName {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

private final class BootoutCancellingLegacyRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let loadedOutput: Data
    private var recordedInvocations: [SubprocessInvocation] = []

    var invocations: [SubprocessInvocation] {
        lock.withLock { recordedInvocations }
    }

    init(loadedOutput: Data) {
        self.loadedOutput = loadedOutput
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        lock.withLock {
            recordedInvocations.append(SubprocessInvocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            ))
        }
        if arguments.first == "bootout" {
            throw CancellationError()
        }
        if arguments.first == "print" {
            stdoutHandler(loadedOutput)
        }
        return SubprocessResult(exitCode: 0, terminationReason: .exit)
    }

    func cancelAll() {}
}
