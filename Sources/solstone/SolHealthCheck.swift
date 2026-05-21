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
        let resolvedSolPath: String
        if let solPath {
            resolvedSolPath = solPath
        } else if let found = await SolBinaryLocator.findSolBinary() {
            resolvedSolPath = found
        } else {
            throw DoctorError.solBinaryNotFound
        }

        let stdoutAccumulator = DataAccumulator()
        let stderrAccumulator = DataAccumulator()
        let result: SubprocessResult
        do {
            result = try await withTimeout(seconds: 10.0) {
                try await runner.run(
                    executable: URL(fileURLWithPath: resolvedSolPath),
                    arguments: ["doctor", "--json"],
                    environment: nil,
                    stdoutHandler: { data in
                        append(data, to: stdoutAccumulator)
                    },
                    stderrHandler: { data in
                        append(data, to: stderrAccumulator)
                    }
                )
            }
        } catch {
            throw DoctorError.subprocessFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        let stderrString = await stderrAccumulator.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0 else {
            throw DoctorError.subprocessFailed(exitCode: result.exitCode, stderr: stderrString.isEmpty ? nil : stderrString)
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
