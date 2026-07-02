// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("JournalHealthCheck")
struct JournalHealthCheckTests {
    private let journalBinary = URL(fileURLWithPath: "/runtime/bin/journal")

    @Test func runUsesJournalHealthOnly() async {
        let runner = FakeDoctorRunner(stdout: Data("ok\n".utf8))

        let result = await JournalHealthCheck.run(journalBinary: journalBinary, runner: runner)

        #expect(result == .healthy)
        #expect(runner.invocations.map(\.executable.lastPathComponent) == ["journal"])
        #expect(runner.invocations.first?.arguments == ["health"])
    }

    @Test func runNonzeroReturnsStoppedDiagnostic() async {
        let runner = FakeDoctorRunner(stderr: Data("/Users/jr/journal failed\n".utf8), exitCode: 1)

        let result = await JournalHealthCheck.run(journalBinary: journalBinary, runner: runner)

        guard case .stopped(let diagnostic) = result else {
            Issue.record("expected stopped, got \(result)")
            return
        }
        #expect(diagnostic.commandLabel == "journal health")
        #expect(diagnostic.exitCode == 1)
        #expect(diagnostic.outputExcerpt?.contains("journal failed") == true)
        #expect(runner.invocations.map(\.executable.lastPathComponent) == ["journal"])
    }

    @Test func versionRunsJournalVersion() async {
        let runner = FakeDoctorRunner(stdout: Data("solstone 1.2.3\n".utf8))

        let version = await JournalHealthCheck.version(journalBinary: journalBinary, runner: runner)

        #expect(version == "1.2.3")
        #expect(runner.invocations == [
            .init(executable: journalBinary, arguments: ["--version"])
        ])
    }

    @Test func doctorDecodesFixtureChecks() async throws {
        let runner = FakeDoctorRunner(stdout: fixture("sol_doctor_ok"))

        let result = await JournalHealthCheck.doctor(
            journalBinary: journalBinary,
            runner: runner,
            fileExists: { _ in true }
        )

        guard case .report(let report) = result else {
            Issue.record("expected report, got \(result)")
            return
        }
        #expect(report.checks.count == 4)
        #expect(report.checks[0].name == "python_version")
        #expect(report.checks[0].status == .ok)
        #expect(report.checks[0].severity == "blocker")
        #expect(report.checks[2].fix == "pip install 'solstone[whisper]'")
        #expect(report.summary == DoctorSummary(total: 4, failed: 0, warnings: 2, skipped: 0))
        #expect(runner.invocations.first?.arguments == ["doctor", "--json"])
        #expect(runner.invocations.first?.executable == journalBinary)
    }

    @Test func doctorNonzeroValidJSONReturnsReport() async {
        let json = #"{"checks":[{"name":"port_available","status":"fail","severity":"blocker","detail":"port busy","fix":"free the port"}],"summary":null}"#
        let runner = FakeDoctorRunner(stdout: Data(json.utf8), exitCode: 1)

        let result = await JournalHealthCheck.doctor(
            journalBinary: journalBinary,
            runner: runner,
            fileExists: { _ in true }
        )

        guard case .report(let report) = result else {
            Issue.record("expected report, got \(result)")
            return
        }
        #expect(report.checks.count == 1)
        #expect(report.checks[0].name == "port_available")
        #expect(report.checks[0].status == .fail)
        #expect(report.checks[0].fix == "free the port")
    }

    @Test func doctorNonzeroAllOKJSONReturnsReport() async {
        let json = #"{"checks":[{"name":"service","status":"ok","severity":null,"detail":"running","fix":null}],"summary":{"total":1,"failed":0,"warnings":0,"skipped":0}}"#
        let runner = FakeDoctorRunner(stdout: Data(json.utf8), exitCode: 1)

        let result = await JournalHealthCheck.doctor(
            journalBinary: journalBinary,
            runner: runner,
            fileExists: { _ in true }
        )

        guard case .report(let report) = result else {
            Issue.record("expected report, got \(result)")
            return
        }
        #expect(report.checks.count == 1)
        #expect(report.checks[0].status == .ok)
        #expect(report.summary == DoctorSummary(total: 1, failed: 0, warnings: 0, skipped: 0))
    }

    @Test func doctorMalformedJSONReturnsUnknown() async {
        let runner = FakeDoctorRunner(stdout: Data("{".utf8))

        let result = await JournalHealthCheck.doctor(
            journalBinary: journalBinary,
            runner: runner,
            fileExists: { _ in true }
        )

        guard case .unknown(let diagnostic) = result else {
            Issue.record("expected unknown, got \(result)")
            return
        }
        #expect(diagnostic.commandLabel == "journal doctor")
        #expect(diagnostic.outputExcerpt?.isEmpty == false)
    }

    @Test func doctorNonzeroMalformedJSONReturnsStopped() async {
        let runner = FakeDoctorRunner(stdout: Data("{".utf8), exitCode: 1)

        let result = await JournalHealthCheck.doctor(
            journalBinary: journalBinary,
            runner: runner,
            fileExists: { _ in true }
        )

        guard case .stopped(let diagnostic) = result else {
            Issue.record("expected stopped, got \(result)")
            return
        }
        #expect(diagnostic.commandLabel == "journal doctor")
        #expect(diagnostic.exitCode == 1)
    }

    @Test func doctorEmptyOutputExitZeroReturnsUnknownNoOutput() async {
        let runner = FakeDoctorRunner()

        let result = await JournalHealthCheck.doctor(
            journalBinary: journalBinary,
            runner: runner,
            fileExists: { _ in true }
        )

        guard case .unknown(let diagnostic) = result else {
            Issue.record("expected unknown, got \(result)")
            return
        }
        #expect(diagnostic.commandLabel == "journal doctor")
        #expect(diagnostic.outputExcerpt == "no output")
    }

    @Test func doctorEmptyOutputNonzeroReturnsStopped() async {
        let runner = FakeDoctorRunner(exitCode: 1)

        let result = await JournalHealthCheck.doctor(
            journalBinary: journalBinary,
            runner: runner,
            fileExists: { _ in true }
        )

        guard case .stopped(let diagnostic) = result else {
            Issue.record("expected stopped, got \(result)")
            return
        }
        #expect(diagnostic.commandLabel == "journal doctor")
        #expect(diagnostic.exitCode == 1)
    }

    @Test func doctorMissingBinaryReturnsSetupNeededWithoutRunning() async {
        let runner = FakeDoctorRunner()

        let result = await JournalHealthCheck.doctor(
            journalBinary: journalBinary,
            runner: runner,
            fileExists: { _ in false }
        )

        #expect(result == .setupNeeded)
        #expect(runner.invocations.isEmpty)
    }

    @Test func doctorUnknownStatusDecodesAsUnknown() throws {
        let status = try JSONDecoder().decode(DoctorStatus.self, from: Data(#""experimental""#.utf8))

        #expect(status == .unknown("experimental"))
        #expect(status != .ok)
    }

    @Test func diagnosticSanitizerCollapsesWhitespaceStripsHomeAndCaps() {
        let long = "/Users/jr/path\n\t" + String(repeating: "x", count: 250)

        let sanitized = sanitizeJournalDiagnosticOutput(long, homeDirectory: "/Users/jr", limit: 40)

        #expect(sanitized == "~/path \(String(repeating: "x", count: 32))…")
    }

    @Test func appProbeChecksMapsPermissions() throws {
        let unknown = appProbeChecks(
            screenRecordingGranted: true,
            microphoneGranted: true,
            permissionCheckComplete: false
        )
        #expect(try #require(unknown.check(named: "screen recording")).status == .warn)
        #expect(try #require(unknown.check(named: "microphone")).status == .warn)

        let denied = appProbeChecks(
            screenRecordingGranted: false,
            microphoneGranted: false,
            permissionCheckComplete: true
        )
        #expect(try #require(denied.check(named: "screen recording")).status == .fail)
        #expect(try #require(denied.check(named: "microphone")).status == .fail)
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/installer")!
        return try! Data(contentsOf: url)
    }
}

private final class FakeDoctorRunner: SubprocessRunning, @unchecked Sendable {
    struct Invocation: Sendable, Equatable {
        let executable: URL
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recordedInvocations: [Invocation] = []
    private let stdout: Data
    private let stderr: Data
    private let exitCode: Int32

    var invocations: [Invocation] {
        lock.withLock { recordedInvocations }
    }

    init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        if executable.lastPathComponent == "sol" {
            Issue.record("unexpected sol subprocess invocation: \(executable.path) \(arguments.joined(separator: " "))")
            throw FakeRunError(message: "unexpected sol subprocess invocation")
        }
        lock.withLock {
            recordedInvocations.append(Invocation(executable: executable, arguments: arguments))
        }
        stdoutHandler(stdout)
        stderrHandler(stderr)
        return SubprocessResult(exitCode: exitCode, terminationReason: .exit)
    }

    func cancelAll() {}
}

private extension Array where Element == DoctorCheck {
    func check(named name: String) -> DoctorCheck? {
        first { $0.name == name }
    }
}
