import ArgumentParser
import Foundation
import SolstoneCore

func formatStatus(_ status: StatusInfo) -> String {
    [
        "isRecording=\(status.isRecording)",
        "isPaused=\(status.isPaused)",
        "pauseAutoResumeAt=\(formatStatusDate(status.pauseAutoResumeAt))",
        "serverURL=\(status.serverURL ?? "<unset>")",
        "serverConfigured=\(status.serverConfigured)",
        "segmentTimeRemainingSeconds=\(status.segmentTimeRemainingSeconds.map(String.init(describing:)) ?? "<unset>")",
        "pendingUploadCount=\(status.pendingUploadCount)",
        "lastSyncedAt=\(formatStatusDate(status.lastSyncedAt))",
        "lastError=\(status.lastError ?? "<unset>")",
        "appVersion=\(status.appVersion)",
        "appBuild=\(status.appBuild)",
        "screenRecordingGranted=\(formatStatusBool(status.screenRecordingGranted))",
        "microphoneGranted=\(formatStatusBool(status.microphoneGranted))"
    ].joined(separator: "\n")
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "show solstone status."
    )

    @Flag(name: .long, help: "emit StatusInfo as JSON.")
    var json: Bool = false

    @Flag(name: .long, help: "launch solstone if not running.")
    var launch: Bool = false

    func run() async throws {
        let request = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .status
        )

        let response = launch
            ? try await sendWithLaunchOrExit(request, command: "status")
            : try await sendOrExit(request, command: "status")

        switch response.result {
        case .ok(.status(let status)):
            if json {
                let data = try IPCWire.encoder.encode(status)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print(formatStatus(status))
            }
        case .ok:
            writeStructuredStderr(code: "ipc_error", message: "unexpected response payload")
            throw ExitCode(SolMacExit.ipcError.rawValue)
        case .error(let err):
            try remapServerError(err, command: "status")
        }
    }
}

private func formatStatusDate(_ value: Date?) -> String {
    guard let value else { return "<unset>" }
    return ISO8601DateFormatter().string(from: value)
}

private func formatStatusBool(_ value: Bool?) -> String {
    guard let value else { return "<unset>" }
    return value ? "true" : "false"
}
