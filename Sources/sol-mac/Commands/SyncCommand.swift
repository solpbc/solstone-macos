import ArgumentParser
import Foundation
import SolstoneCore

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "trigger a sync now."
    )

    @Flag(name: .long, help: "launch solstone if not running.")
    var launch: Bool = false

    func run() async throws {
        let request = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .syncNow
        )

        let response = launch
            ? try await sendWithLaunchOrExit(request, command: "sync")
            : try await sendOrExit(request, command: "sync")

        switch response.result {
        case .ok(.empty):
            return
        case .ok:
            writeStructuredStderr(code: "ipc_error", message: "unexpected response payload")
            throw ExitCode(SolMacExit.ipcError.rawValue)
        case .error(let error):
            try remapServerError(error, command: "sync")
        }
    }
}
