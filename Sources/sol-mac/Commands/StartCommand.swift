import ArgumentParser
import Foundation
import SolstoneCore

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "start solstone recording."
    )

    @Flag(name: .long, help: "launch solstone if not running.")
    var launch: Bool = false

    func run() async throws {
        let request = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .start
        )

        let response = launch
            ? try await sendWithLaunchOrExit(request, command: "start")
            : try await sendOrExit(request, command: "start")

        switch response.result {
        case .ok(.empty):
            return
        case .ok:
            writeStructuredStderr(code: "ipc_error", message: "unexpected response payload")
            throw ExitCode(SolMacExit.ipcError.rawValue)
        case .error(let error):
            try remapServerError(error, command: "start")
        }
    }
}
