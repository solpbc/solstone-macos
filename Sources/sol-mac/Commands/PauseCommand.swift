import ArgumentParser
import Foundation
import SolstoneCore

func parsePauseDuration(_ input: String) throws -> Int {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ValidationError("invalid pause duration: \(input)")
    }

    if let seconds = Int(trimmed) {
        guard seconds >= 0 else {
            throw ValidationError("invalid pause duration: \(input)")
        }
        return seconds
    }

    guard let suffix = trimmed.last else {
        throw ValidationError("invalid pause duration: \(input)")
    }

    let magnitudeString = String(trimmed.dropLast())
    guard let magnitude = Int(magnitudeString), magnitude >= 0 else {
        throw ValidationError("invalid pause duration: \(input)")
    }

    switch suffix {
    case "s":
        return magnitude
    case "m":
        return magnitude * 60
    case "h":
        return magnitude * 3_600
    case "d":
        return magnitude * 86_400
    default:
        throw ValidationError("invalid pause duration: \(input)")
    }
}

struct PauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "pause solstone recording."
    )

    @Option(name: .customLong("for"), help: "pause duration (30s, 30m, 2h, 1d, or bare seconds).")
    var duration: String?

    func run() async throws {
        let seconds: Int
        do {
            seconds = try parsePauseDuration(duration ?? "0")
        } catch {
            writeStructuredStderr(code: "invalid_args", message: "invalid pause duration: \(duration ?? "")")
            throw ExitCode(SolMacExit.invalidArgs.rawValue)
        }

        let request = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .pause(seconds: seconds)
        )

        let response = try await sendOrExit(request, command: "pause")
        switch response.result {
        case .ok(.empty):
            return
        case .ok:
            writeStructuredStderr(code: "ipc_error", message: "unexpected response payload")
            throw ExitCode(SolMacExit.ipcError.rawValue)
        case .error(let error):
            try remapServerError(error, command: "pause")
        }
    }
}
