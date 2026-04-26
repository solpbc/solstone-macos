import ArgumentParser
import Foundation
import SolstoneCore

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "stop solstone recording."
    )

    func run() async throws {
        let request = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .stop
        )

        let response: IPCResponse
        do {
            response = try await SolMacClient.send(request)
        } catch let error as SolMacClientError {
            switch error {
            case .appNotRunning:
                print(SolMacCopy.stopNoop)
                throw ExitCode(SolMacExit.success.rawValue)
            case .timeout:
                writeStructuredStderr(code: "ipc_timeout", message: SolMacCopy.ipcTimeout)
                throw ExitCode(SolMacExit.ipcError.rawValue)
            case .decodeFailed(let underlying):
                writeStructuredStderr(code: "decode_failed", message: "decode failed: \(underlying)")
                throw ExitCode(SolMacExit.ipcError.rawValue)
            }
        }

        try validateResponseProtocol(response)

        switch response.result {
        case .ok(.empty):
            return
        case .ok:
            writeStructuredStderr(code: "ipc_error", message: "unexpected response payload")
            throw ExitCode(SolMacExit.ipcError.rawValue)
        case .error(let error):
            try remapServerError(error, command: "stop")
        }
    }
}
