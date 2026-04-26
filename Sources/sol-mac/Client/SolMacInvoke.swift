import ArgumentParser
import Foundation
import ServiceManagement
import SolstoneCore

func resolveAppBundlePath() -> URL? {
    let fixedPaths = [
        URL(fileURLWithPath: "/Applications/solstone.app"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/solstone.app")
    ]

    for path in fixedPaths where FileManager.default.fileExists(atPath: path.path) {
        return path
    }

    return nil
}

func launchApp() throws {
    guard let appPath = resolveAppBundlePath() else {
        writeStructuredStderr(code: "local_validation", message: "could not resolve solstone.app")
        throw ExitCode(SolMacExit.localValidation.rawValue)
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = ["-gj", appPath.path]

    do {
        try proc.run()
    } catch {
        writeStructuredStderr(code: "local_validation", message: "launch failed: \(error.localizedDescription)")
        throw ExitCode(SolMacExit.localValidation.rawValue)
    }
}

func awaitPingReady(
    socketURL: URL = SolMacIPCConstants.socketURL,
    deadline: TimeInterval = 8.0
) async -> Bool {
    let end = Date().addingTimeInterval(deadline)
    var delayMilliseconds: UInt64 = 50

    while Date() < end {
        let request = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .ping
        )

        do {
            let response = try await SolMacClient.send(
                request,
                socketURL: socketURL,
                connectTimeout: .milliseconds(200),
                requestTimeout: .milliseconds(500)
            )
            if case .ok(.pong) = response.result {
                return true
            }
        } catch {
            // Keep polling until the deadline expires.
        }

        try? await Task.sleep(for: .milliseconds(Int(delayMilliseconds)))
        delayMilliseconds = min(delayMilliseconds * 2, 500)
    }

    return false
}

func loginRaceShouldRetry() -> Bool {
    // docs: unbundled CLI invocations resolve to .notFound here, which safely disables the retry path.
    SMAppService.mainApp.status == .enabled
}

func sendOrExit(
    _ request: IPCRequest,
    command: String,
    allowLoginRaceRetry: Bool = true
) async throws -> IPCResponse {
    do {
        let response = try await performSend(request, allowLoginRaceRetry: allowLoginRaceRetry)
        try validateResponseProtocol(response)
        return response
    } catch let error as SolMacClientError {
        try handleClientErrorAndExit(error)
    }
}

func sendWithLaunchOrExit(_ request: IPCRequest, command: String) async throws -> IPCResponse {
    do {
        let response = try await performSend(request, allowLoginRaceRetry: false)
        try validateResponseProtocol(response)
        return response
    } catch let error as SolMacClientError {
        if case .appNotRunning = error {
            try launchApp()
            guard await awaitPingReady() else {
                writeStructuredStderr(code: "internal_error", message: "app failed to become ready")
                throw ExitCode(SolMacExit.ipcError.rawValue)
            }
            return try await sendOrExit(request, command: command, allowLoginRaceRetry: false)
        }
        try handleClientErrorAndExit(error)
    }
}

func validateResponseProtocol(_ response: IPCResponse) throws {
    if response.serverProtocolVersion != SolMacIPCConstants.currentProtocolVersion {
        writeStderr(
            SolMacCopy.versionMismatch(
                cliVersion: String(SolMacIPCConstants.currentProtocolVersion),
                appVersion: String(response.serverProtocolVersion)
            )
        )
        throw ExitCode(SolMacExit.versionMismatch.rawValue)
    }

    if case .error(let error) = response.result, error.code == "version_mismatch" {
        writeStderr(
            SolMacCopy.versionMismatch(
                cliVersion: String(SolMacIPCConstants.currentProtocolVersion),
                appVersion: String(response.serverProtocolVersion)
            )
        )
        throw ExitCode(SolMacExit.versionMismatch.rawValue)
    }
}

func remapServerError(_ error: IPCError, command: String) throws -> Never {
    switch (command, error.code) {
    case ("stop", "already_in_state"):
        print(SolMacCopy.STOP_NOOP)
        throw ExitCode(SolMacExit.success.rawValue)
    case ("pause", "already_in_state"), ("unpause", "already_in_state"):
        writeStructuredStderr(code: error.code, message: error.message)
        throw ExitCode(SolMacExit.success.rawValue)
    case (_, "not_configured") where command == "sync":
        writeStructuredStderr(code: error.code, message: error.message, hint: error.hint)
        throw ExitCode(SolMacExit.localValidation.rawValue)
    default:
        writeStructuredStderr(code: error.code, message: error.message, hint: error.hint)
        throw ExitCode(SolMacExit.ipcError.rawValue)
    }
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data(message.appending("\n").utf8))
}

func writeStructuredStderr(code: String, message: String, hint: String? = nil) {
    var line = "code: \(code), message: \(message)"
    if let hint {
        line += ", hint: \(hint)"
    }
    writeStderr(line)
}

private func performSend(_ request: IPCRequest, allowLoginRaceRetry: Bool) async throws -> IPCResponse {
    do {
        return try await SolMacClient.send(request)
    } catch let error as SolMacClientError {
        if case .appNotRunning = error, allowLoginRaceRetry, loginRaceShouldRetry() {
            try await Task.sleep(for: .milliseconds(500))
            return try await SolMacClient.send(request)
        }
        throw error
    }
}

private func handleClientErrorAndExit(_ error: SolMacClientError) throws -> Never {
    switch error {
    case .appNotRunning:
        writeStderr(SolMacCopy.APP_NOT_RUNNING)
        throw ExitCode(SolMacExit.appNotRunning.rawValue)
    case .timeout:
        writeStructuredStderr(code: "ipc_timeout", message: "ipc timeout")
        throw ExitCode(SolMacExit.ipcError.rawValue)
    case .decodeFailed(let underlying):
        writeStructuredStderr(code: "decode_failed", message: "decode failed: \(underlying)")
        throw ExitCode(SolMacExit.ipcError.rawValue)
    }
}
