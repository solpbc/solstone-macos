// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SolHealthCheck")
struct SolHealthCheckTests {
    @Test func doctorDecodesFixtureChecks() async throws {
        let runner = FakeDoctorRunner(stdout: fixture("sol_doctor_ok"))

        let report = try await SolHealthCheck.doctor(runner: runner, solPath: "/usr/bin/sol")

        #expect(report.checks.count == 4)
        #expect(report.checks[0].name == "python_version")
        #expect(report.checks[0].status == .ok)
        #expect(report.checks[0].severity == "blocker")
        #expect(report.checks[2].fix == "pip install 'solstone[whisper]'")
        #expect(report.summary == DoctorSummary(total: 4, failed: 0, warnings: 2, skipped: 0))
        #expect(runner.invocations.first?.arguments == ["doctor", "--json"])
    }

    @Test func doctorThrowsOnParseFailure() async throws {
        let runner = FakeDoctorRunner(stdout: Data("{".utf8))

        await #expect(throws: DoctorError.self) {
            _ = try await SolHealthCheck.doctor(runner: runner, solPath: "/usr/bin/sol")
        }
    }

    @Test func doctorReturnsReportOnNonZeroExitWithFailingCheck() async throws {
        let json = #"{"checks":[{"name":"port_available","status":"fail","severity":"blocker","detail":"port busy","fix":"free the port"}],"summary":null}"#
        let runner = FakeDoctorRunner(stdout: Data(json.utf8), exitCode: 1)

        let report = try await SolHealthCheck.doctor(runner: runner, solPath: "/usr/bin/sol")

        #expect(report.checks.contains { $0.status == .fail })
    }

    @Test func doctorThrowsEmptyOutputOnNonZeroExitWithEmptyStdout() async throws {
        let runner = FakeDoctorRunner(stderr: Data("port busy\n".utf8), exitCode: 2)

        await #expect(throws: DoctorError.emptyOutput) {
            _ = try await SolHealthCheck.doctor(runner: runner, solPath: "/usr/bin/sol")
        }
    }

    @Test func doctorThrowsParseFailureOnNonZeroExitWithGarbage() async throws {
        let runner = FakeDoctorRunner(stdout: Data("{".utf8), exitCode: 1)

        await #expect(throws: DoctorError.self) {
            _ = try await SolHealthCheck.doctor(runner: runner, solPath: "/usr/bin/sol")
        }
    }

    @Test func doctorUnknownStatusDecodesAsUnknown() throws {
        let status = try JSONDecoder().decode(DoctorStatus.self, from: Data(#""experimental""#.utf8))

        #expect(status == .unknown("experimental"))
    }

    @Test func doctorUnknownStatusDoesNotDecodeAsOk() throws {
        let status = try JSONDecoder().decode(DoctorStatus.self, from: Data(#""experimental""#.utf8))

        #expect(status != .ok)
    }

    @Test func journalDoctorReturnsJournalReportWhenAvailable() async throws {
        let runner = FakeDoctorRunner(responses: [
            "journal": .init(stdout: doctorJSON(name: "journal_check", status: "ok", detail: "journal")),
            "sol": .init(stdout: doctorJSON(name: "sol_check", status: "ok", detail: "sol")),
        ])

        let report = try await SolHealthCheck.journalDoctorWithFallback(
            runner: runner,
            solPath: "/usr/bin/sol"
        )

        #expect(report.checks.first?.name == "journal_check")
        #expect(runner.invocations.map { $0.executable.lastPathComponent } == ["journal"])
        #expect(runner.invocations.first?.arguments == ["doctor", "--json"])
    }

    @Test func journalDoctorFallsBackToSolWhenJournalUnavailable() async throws {
        let runner = FakeDoctorRunner(responses: [
            "journal": .init(stderr: Data("missing\n".utf8), exitCode: 2),
            "sol": .init(stdout: doctorJSON(name: "sol_check", status: "ok", detail: "sol")),
        ])

        let report = try await SolHealthCheck.journalDoctorWithFallback(
            runner: runner,
            solPath: "/usr/bin/sol"
        )

        #expect(report.checks.first?.name == "sol_check")
        #expect(runner.invocations.map { $0.executable.lastPathComponent } == ["journal", "sol"])
        #expect(runner.invocations.allSatisfy { $0.arguments == ["doctor", "--json"] })
    }

    @Test func journalDoctorDoesNotFallbackOnNonZeroExitWithValidJSON() async throws {
        let runner = FakeDoctorRunner(responses: [
            "journal": .init(stdout: doctorJSON(name: "journal_fail", status: "fail", detail: "journal"), exitCode: 1),
            "sol": .init(stdout: doctorJSON(name: "sol_check", status: "ok", detail: "sol")),
        ])

        let report = try await SolHealthCheck.journalDoctorWithFallback(
            runner: runner,
            solPath: "/usr/bin/sol"
        )

        #expect(report.checks.first?.name == "journal_fail")
        #expect(report.checks.first?.status == .fail)
        #expect(runner.invocations.map { $0.executable.lastPathComponent } == ["journal"])
    }

    @Test func appProbeChecksMapsPermissionsAndIPC() throws {
        let unknown = appProbeChecks(
            screenRecordingGranted: true,
            microphoneGranted: true,
            permissionCheckComplete: false,
            ipcServiceRunning: true
        )
        #expect(try #require(unknown.check(named: "screen recording")).status == .warn)
        #expect(try #require(unknown.check(named: "screen recording")).detail == "unknown — checking permissions")
        #expect(try #require(unknown.check(named: "microphone")).status == .warn)
        #expect(try #require(unknown.check(named: "microphone")).detail == "unknown — checking permissions")
        #expect(try #require(unknown.check(named: "ipc service")).status == .ok)
        #expect(try #require(unknown.check(named: "ipc service")).detail == "ipc service running")

        let denied = appProbeChecks(
            screenRecordingGranted: false,
            microphoneGranted: false,
            permissionCheckComplete: true,
            ipcServiceRunning: false
        )
        #expect(try #require(denied.check(named: "screen recording")).status == .fail)
        #expect(try #require(denied.check(named: "screen recording")).detail == "denied")
        #expect(try #require(denied.check(named: "screen recording")).fix?.contains("System Settings › Privacy & Security") == true)
        #expect(try #require(denied.check(named: "microphone")).status == .fail)
        #expect(try #require(denied.check(named: "microphone")).detail == "denied")
        #expect(try #require(denied.check(named: "microphone")).fix?.contains("System Settings › Privacy & Security") == true)
        #expect(try #require(denied.check(named: "ipc service")).status == .warn)
        #expect(try #require(denied.check(named: "ipc service")).detail == "ipc service not available")

        let granted = appProbeChecks(
            screenRecordingGranted: true,
            microphoneGranted: true,
            permissionCheckComplete: true,
            ipcServiceRunning: true
        )
        #expect(try #require(granted.check(named: "screen recording")).status == .ok)
        #expect(try #require(granted.check(named: "screen recording")).detail == "granted")
        #expect(try #require(granted.check(named: "microphone")).status == .ok)
        #expect(try #require(granted.check(named: "microphone")).detail == "granted")
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/installer")!
        return try! Data(contentsOf: url)
    }

    private func doctorJSON(name: String, status: String, detail: String) -> Data {
        Data(#"{"checks":[{"name":"\#(name)","status":"\#(status)","severity":null,"detail":"\#(detail)","fix":null}],"summary":null}"#.utf8)
    }
}

private final class FakeDoctorRunner: SubprocessRunning, @unchecked Sendable {
    struct Invocation: Sendable, Equatable {
        let executable: URL
        let arguments: [String]
    }

    struct Response: Sendable {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32

        init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    private let defaultResponse: Response
    private let responses: [String: Response]

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0) {
        self.defaultResponse = Response(stdout: stdout, stderr: stderr, exitCode: exitCode)
        self.responses = [:]
    }

    init(responses: [String: Response], defaultResponse: Response = Response()) {
        self.defaultResponse = defaultResponse
        self.responses = responses
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        lock.withLock {
            _invocations.append(Invocation(executable: executable, arguments: arguments))
        }
        let response = responses[executable.lastPathComponent] ?? defaultResponse
        stdoutHandler(response.stdout)
        stderrHandler(response.stderr)
        return SubprocessResult(exitCode: response.exitCode, terminationReason: .exit)
    }

    func cancelAll() {}
}

private extension Array where Element == DoctorCheck {
    func check(named name: String) -> DoctorCheck? {
        first { $0.name == name }
    }
}
