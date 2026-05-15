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

    @Test func doctorThrowsOnNonZeroExit() async throws {
        let runner = FakeDoctorRunner(stderr: Data("port busy\n".utf8), exitCode: 2)

        await #expect(throws: DoctorError.subprocessFailed(exitCode: 2, stderr: "port busy")) {
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
    private var _invocations: [Invocation] = []
    private let stdout: Data
    private let stderr: Data
    private let exitCode: Int32

    var invocations: [Invocation] {
        lock.withLock { _invocations }
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
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        lock.withLock {
            _invocations.append(Invocation(executable: executable, arguments: arguments))
        }
        stdoutHandler(stdout)
        stderrHandler(stderr)
        return SubprocessResult(exitCode: exitCode, terminationReason: .exit)
    }

    func cancelAll() {}
}
