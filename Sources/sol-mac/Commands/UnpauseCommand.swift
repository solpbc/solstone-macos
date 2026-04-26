import ArgumentParser
import Foundation
import SolstoneCore

struct UnpauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpause",
        abstract: "resume solstone recording."
    )

    func run() async throws {
        let request = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .unpause
        )

        let response = try await sendOrExit(request, command: "unpause")
        switch response.result {
        case .ok(.empty):
            return
        case .ok:
            writeStructuredStderr(code: "ipc_error", message: "unexpected response payload")
            throw ExitCode(SolMacExit.ipcError.rawValue)
        case .error(let error):
            try remapServerError(error, command: "unpause")
        }
    }
}
