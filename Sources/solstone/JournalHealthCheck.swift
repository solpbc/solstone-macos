import Foundation
import os

public struct JournalDiagnostic: Equatable, Sendable {
    public let commandLabel: String
    public let timedOut: Bool
    public let exitCode: Int32?
    public let outputExcerpt: String?

    public init(
        commandLabel: String,
        timedOut: Bool = false,
        exitCode: Int32? = nil,
        outputExcerpt: String? = nil
    ) {
        self.commandLabel = commandLabel
        self.timedOut = timedOut
        self.exitCode = exitCode
        self.outputExcerpt = outputExcerpt
    }
}

public enum JournalRuntimeStatus: Equatable, Sendable {
    case running
    case stopped(JournalDiagnostic)
    case stoppedByUser
    case restarting
    case setupNeeded
    case unknown(JournalDiagnostic)

    var diagnostic: JournalDiagnostic? {
        switch self {
        case .stopped(let diagnostic), .unknown(let diagnostic):
            return diagnostic
        case .running, .stoppedByUser, .restarting, .setupNeeded:
            return nil
        }
    }

    var isRestarting: Bool {
        if case .restarting = self { return true }
        return false
    }

    var isSetupNeeded: Bool {
        if case .setupNeeded = self { return true }
        return false
    }

    var isStoppedByUser: Bool {
        if case .stoppedByUser = self { return true }
        return false
    }

}

enum JournalHealthCheckResult: Equatable, Sendable {
    case healthy
    case stopped(JournalDiagnostic)
    case unknown(JournalDiagnostic)
}

enum JournalDoctorResult: Equatable, Sendable {
    case report(DoctorReport)
    case setupNeeded
    case stopped(JournalDiagnostic)
    case unknown(JournalDiagnostic)
}

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

enum JournalHealthCheck {
    static func run(
        journalBinary: URL,
        runner: SubprocessRunning = SubprocessRunner(),
        environment: [String: String]? = nil
    ) async -> JournalHealthCheckResult {
        let output = LockedHealthOutput()
        do {
            let result = try await withTimeout(seconds: 5.0) {
                try await runner.run(
                    executable: journalBinary,
                    arguments: ["health"],
                    environment: environment,
                    stdoutHandler: { data in output.append(data) },
                    stderrHandler: { data in output.append(data) }
                )
            }
            if result.exitCode == 0 {
                Logger.setup.info("journal health: ok")
                return .healthy
            }
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal health",
                exitCode: result.exitCode,
                outputExcerpt: sanitizeJournalDiagnosticOutput(output.string)
            )
            Logger.setup.info("journal health: stopped exit=\(result.exitCode, privacy: .public)")
            return .stopped(diagnostic)
        } catch is TimeoutError {
            return .unknown(JournalDiagnostic(
                commandLabel: "journal health",
                timedOut: true,
                outputExcerpt: sanitizeJournalDiagnosticOutput(output.string)
            ))
        } catch {
            return .unknown(JournalDiagnostic(
                commandLabel: "journal health",
                outputExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
            ))
        }
    }

    static func version(
        journalBinary: URL,
        runner: SubprocessRunning = SubprocessRunner(),
        environment: [String: String]? = nil,
        timeout: Duration? = nil
    ) async -> String? {
        let output = LockedHealthOutput()
        do {
            let result = try await runner.run(
                executable: journalBinary,
                arguments: ["--version"],
                environment: environment,
                timeout: timeout,
                stdoutHandler: { data in output.append(data) },
                stderrHandler: { _ in }
            )
            guard result.exitCode == 0 else { return nil }
            return SolVersionParser.parse(output.string)
        } catch {
            return nil
        }
    }

    static func doctor(
        journalBinary: URL,
        runner: SubprocessRunning = SubprocessRunner(),
        fileExists: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async -> JournalDoctorResult {
        guard fileExists(journalBinary.path) else {
            return .setupNeeded
        }

        let output = LockedSplitHealthOutput()
        let result: SubprocessResult
        do {
            result = try await withTimeout(seconds: 10.0) {
                try await runner.run(
                    executable: journalBinary,
                    arguments: ["doctor", "--json"],
                    environment: nil,
                    stdoutHandler: { data in output.append(data, stream: .stdout) },
                    stderrHandler: { data in output.append(data, stream: .stderr) }
                )
            }
        } catch is TimeoutError {
            return .unknown(JournalDiagnostic(
                commandLabel: "journal doctor",
                timedOut: true,
                outputExcerpt: sanitizeJournalDiagnosticOutput(output.combinedString)
            ))
        } catch {
            return .unknown(JournalDiagnostic(
                commandLabel: "journal doctor",
                outputExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
            ))
        }

        let stdout = output.stdoutString
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStdout.isEmpty {
            do {
                return .report(try JSONDecoder().decode(DoctorReport.self, from: Data(stdout.utf8)))
            } catch {
                if result.exitCode != 0 {
                    return .stopped(JournalDiagnostic(
                        commandLabel: "journal doctor",
                        exitCode: result.exitCode,
                        outputExcerpt: sanitizeJournalDiagnosticOutput(output.combinedString)
                    ))
                }
                return .unknown(JournalDiagnostic(
                    commandLabel: "journal doctor",
                    outputExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
                ))
            }
        }
        if result.exitCode != 0 {
            return .stopped(JournalDiagnostic(
                commandLabel: "journal doctor",
                exitCode: result.exitCode,
                outputExcerpt: sanitizeJournalDiagnosticOutput(output.combinedString)
            ))
        }
        return .unknown(JournalDiagnostic(
            commandLabel: "journal doctor",
            outputExcerpt: "no output"
        ))
    }
}

internal enum JournalRuntimeProbeOutcome: Equatable, Sendable {
    case reachable
    case unreachable(JournalDiagnostic)
    case unknown(JournalDiagnostic)
    case binaryMissing
}

internal enum JournalRuntimeProbe {
    static func run(
        journalBinary: URL,
        runner: SubprocessRunning = SubprocessRunner(),
        fileExists: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async -> JournalRuntimeProbeOutcome {
        guard fileExists(journalBinary.path) else {
            return .binaryMissing
        }

        switch await JournalHealthCheck.run(journalBinary: journalBinary, runner: runner) {
        case .healthy:
            return .reachable
        case .stopped(let diagnostic):
            return .unreachable(diagnostic)
        case .unknown(let diagnostic):
            return .unknown(diagnostic)
        }
    }
}

func appProbeChecks(
    screenRecordingGranted: Bool,
    microphoneGranted: Bool,
    permissionCheckComplete: Bool
) -> [DoctorCheck] {
    [
        permissionProbeCheck(
            name: "screen recording",
            granted: screenRecordingGranted,
            permissionCheckComplete: permissionCheckComplete,
            fix: "open System Settings › Privacy & Security and allow Screen Recording for sol"
        ),
        permissionProbeCheck(
            name: "microphone",
            granted: microphoneGranted,
            permissionCheckComplete: permissionCheckComplete,
            fix: "open System Settings › Privacy & Security and allow Microphone for sol"
        ),
    ]
}

internal func sanitizeJournalDiagnosticOutput(
    _ output: String?,
    homeDirectory: String = NSHomeDirectory(),
    limit: Int = 200
) -> String? {
    guard var value = output else { return nil }
    value = value.replacingOccurrences(of: homeDirectory, with: "~")
    value = value.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard !value.isEmpty else { return nil }
    guard value.count > limit else { return value }
    let prefix = value.prefix(max(0, limit - 1))
    return "\(prefix)…"
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

private final class LockedHealthOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var string: String {
        lock.withLock { String(data: data, encoding: .utf8) ?? "" }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }
}

private final class LockedSplitHealthOutput: @unchecked Sendable {
    enum Stream {
        case stdout
        case stderr
    }

    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    var stdoutString: String {
        lock.withLock { String(data: stdout, encoding: .utf8) ?? "" }
    }

    var combinedString: String {
        lock.withLock {
            [String(data: stdout, encoding: .utf8) ?? "", String(data: stderr, encoding: .utf8) ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    func append(_ chunk: Data, stream: Stream) {
        lock.withLock {
            switch stream {
            case .stdout:
                stdout.append(chunk)
            case .stderr:
                stderr.append(chunk)
            }
        }
    }
}
