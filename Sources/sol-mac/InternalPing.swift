import ArgumentParser
import Foundation
import SolstoneCore

struct InternalPing: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_internal-ping",
        abstract: "Internal IPC ping.",
        shouldDisplay: false
    )

    mutating func run() async throws {
        let response = try await SolMacClient.send(
            IPCRequest(
                id: UUID(),
                protocolVersion: SolMacIPCConstants.currentProtocolVersion,
                command: .ping
            )
        )

        switch response.result {
        case .ok(.pong):
            print("pong")
        case .ok:
            writeStructuredStderr(code: "ipc_error", message: "unexpected response payload")
            throw ExitCode(SolMacExit.ipcError.rawValue)
        case .error(let error):
            writeStructuredStderr(code: error.code, message: error.message, hint: error.hint)
        }
    }
}
