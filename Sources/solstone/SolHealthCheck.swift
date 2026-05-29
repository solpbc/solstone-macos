import Foundation
import os

struct DoctorCheck: Decodable, Equatable, Sendable {
    let name: String
    let status: DoctorStatus
    let severity: String?
    let detail: String?
    let fix: String?
}

enum DoctorStatus: Decodable, Equatable, Sendable {
    case ok
    case warn
    case fail
    case skip
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "ok":
            self = .ok
        case "warn":
            self = .warn
        case "fail":
            self = .fail
        case "skip":
            self = .skip
        default:
            self = .unknown(raw)
        }
    }
}

struct DoctorReport: Decodable, Equatable, Sendable {
    let checks: [DoctorCheck]
    let summary: DoctorSummary?
}

enum DoctorError: Error, LocalizedError, Equatable {
    case solBinaryNotFound
    case subprocessFailed(exitCode: Int32, stderr: String?)
    case emptyOutput
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .solBinaryNotFound:
            return "sol binary not found"
        case .subprocessFailed(let exitCode, let stderr):
            if let stderr, !stderr.isEmpty {
                return "sol doctor failed (\(exitCode)): \(stderr)"
            }
            return "sol doctor failed (\(exitCode))"
        case .emptyOutput:
            return "sol doctor returned no output"
        case .parseFailed(let message):
            return "sol doctor output could not be read: \(message)"
        }
    }
}

enum SolHealthCheck {
    static func run(solPath: String, runner: SubprocessRunning = SubprocessRunner()) async -> Bool {
        do {
            let result = try await withTimeout(seconds: 5.0) {
                try await runner.run(
                    executable: URL(fileURLWithPath: solPath),
                    arguments: ["health"],
                    environment: nil,
                    stdoutHandler: { _ in },
                    stderrHandler: { _ in }
                )
            }
            if result.exitCode == 0 {
                Logger.setup.info("sol health: ok")
                return true
            }
            Logger.setup.info("sol health: unhealthy(exitCode=\(result.exitCode, privacy: .public))")
            return false
        } catch is TimeoutError {
            Logger.setup.info("sol health: unhealthy(timeout)")
            return false
        } catch {
            Logger.setup.info("sol health: unhealthy(error=\(String(describing: error), privacy: .public))")
            return false
        }
    }

    static func version(solPath: String, runner: SubprocessRunning = SubprocessRunner()) async -> String? {
        let stdoutAccumulator = DataAccumulator()
        do {
            let result = try await withTimeout(seconds: 5.0) {
                try await runner.run(
                    executable: URL(fileURLWithPath: solPath),
                    arguments: ["--version"],
                    environment: nil,
                    stdoutHandler: { data in
                        append(data, to: stdoutAccumulator)
                    },
                    stderrHandler: { _ in }
                )
            }
            guard result.exitCode == 0 else { return nil }
            let stdoutString = await stdoutAccumulator.string
            return SolVersionParser.parse(stdoutString)
        } catch {
            return nil
        }
    }

    static func doctor(runner: SubprocessRunner = SubprocessRunner(), solPath: String? = nil) async throws -> DoctorReport {
        try await doctor(runner: runner as SubprocessRunning, solPath: solPath)
    }

    static func doctor(runner: SubprocessRunning, solPath: String? = nil) async throws -> DoctorReport {
        let resolvedSolPath = try await resolveSolPath(solPath)

        return try await runDoctor(executable: URL(fileURLWithPath: resolvedSolPath), runner: runner)
    }

    static func journalDoctorWithFallback(
        runner: SubprocessRunner = SubprocessRunner(),
        solPath: String? = nil
    ) async throws -> DoctorReport {
        try await journalDoctorWithFallback(runner: runner as SubprocessRunning, solPath: solPath)
    }

    static func journalDoctorWithFallback(
        runner: SubprocessRunning,
        solPath: String? = nil
    ) async throws -> DoctorReport {
        let resolvedSolPath = try await resolveSolPath(solPath)
        let solURL = URL(fileURLWithPath: resolvedSolPath)
        let journalURL = URL(fileURLWithPath: SolBinaryLocator.journalPath(siblingOf: resolvedSolPath))

        do {
            return try await runDoctor(executable: journalURL, runner: runner)
        } catch is DoctorError {
            // Forward-compat: older runtimes may not have `journal doctor`.
            return try await runDoctor(executable: solURL, runner: runner)
        }
    }

    private static func resolveSolPath(_ solPath: String?) async throws -> String {
        let resolvedSolPath: String
        if let solPath {
            resolvedSolPath = solPath
        } else if let found = await SolBinaryLocator.findSolBinary() {
            resolvedSolPath = found
        } else {
            throw DoctorError.solBinaryNotFound
        }
        return resolvedSolPath
    }

    private static func runDoctor(executable: URL, runner: SubprocessRunning) async throws -> DoctorReport {
        let stdoutAccumulator = DataAccumulator()
        do {
            _ = try await withTimeout(seconds: 10.0) {
                try await runner.run(
                    executable: executable,
                    arguments: ["doctor", "--json"],
                    environment: nil,
                    stdoutHandler: { data in
                        append(data, to: stdoutAccumulator)
                    },
                    stderrHandler: { _ in }
                )
            }
        } catch {
            throw DoctorError.subprocessFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        let stdoutString = await stdoutAccumulator.string
        guard !stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DoctorError.emptyOutput
        }

        do {
            return try JSONDecoder().decode(DoctorReport.self, from: Data(stdoutString.utf8))
        } catch {
            throw DoctorError.parseFailed(error.localizedDescription)
        }
    }

    private static func append(_ data: Data, to accumulator: DataAccumulator) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await accumulator.append(data)
            semaphore.signal()
        }
        semaphore.wait()
    }
}

func appProbeChecks(
    screenRecordingGranted: Bool,
    microphoneGranted: Bool,
    permissionCheckComplete: Bool,
    ipcServiceRunning: Bool
) -> [DoctorCheck] {
    [
        permissionProbeCheck(
            name: "screen recording",
            granted: screenRecordingGranted,
            permissionCheckComplete: permissionCheckComplete,
            fix: "open System Settings › Privacy & Security and allow Screen Recording for solstone observer"
        ),
        permissionProbeCheck(
            name: "microphone",
            granted: microphoneGranted,
            permissionCheckComplete: permissionCheckComplete,
            fix: "open System Settings › Privacy & Security and allow Microphone for solstone observer"
        ),
        DoctorCheck(
            name: "ipc service",
            status: ipcServiceRunning ? .ok : .warn,
            severity: nil,
            detail: ipcServiceRunning ? "ipc service running" : "ipc service not available",
            fix: nil
        ),
    ]
}

private func permissionProbeCheck(
    name: String,
    granted: Bool,
    permissionCheckComplete: Bool,
    fix: String
) -> DoctorCheck {
    if !permissionCheckComplete {
        return DoctorCheck(
            name: name,
            status: .warn,
            severity: nil,
            detail: "unknown — checking permissions",
            fix: nil
        )
    }

    if granted {
        return DoctorCheck(
            name: name,
            status: .ok,
            severity: nil,
            detail: "granted",
            fix: nil
        )
    }

    return DoctorCheck(
        name: name,
        status: .fail,
        severity: nil,
        detail: "denied",
        fix: fix
    )
}

internal enum PipelineLivenessProbeOutcome: Equatable, Sendable {
    case reachable
    case unreachable
    case binaryMissing
}

internal enum PipelineLivenessProbe {
    static func run(
        runner: SubprocessRunning = SubprocessRunner(),
        findSolBinary: @Sendable () async -> String? = { await SolBinaryLocator.findSolBinary() }
    ) async -> PipelineLivenessProbeOutcome {
        guard let solPath = await findSolBinary() else {
            return .binaryMissing
        }
        return await SolHealthCheck.run(solPath: solPath, runner: runner) ? .reachable : .unreachable
    }
}

private actor DataAccumulator {
    private var data = Data()

    var string: String {
        String(data: data, encoding: .utf8) ?? ""
    }

    func append(_ chunk: Data) {
        data.append(chunk)
    }
}
