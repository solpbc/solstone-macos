import ArgumentParser
import Foundation
import SolstoneCore

let openTabWhitelist: Set<String> = [
    "general",
    "permissions",
    "service",
    "microphones",
    "privacy",
    "help",
    "status",
    "updates"
]

func openTabWarning(for tab: String?) -> String? {
    guard let tab, !openTabWhitelist.contains(tab) else { return nil }
    return "warning: unknown tab '\(tab)'; window will open without changing pane"
}

struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "open solstone settings."
    )

    @Argument(help: "optional settings tab.")
    var tab: String?

    @Flag(name: .long, help: "launch solstone if not running.")
    var launch: Bool = false

    func run() async throws {
        if let warning = openTabWarning(for: tab) {
            writeStderr(warning)
        }

        let request = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .openSettings(tab: tab)
        )

        let response = launch
            ? try await sendWithLaunchOrExit(request, command: "open")
            : try await sendOrExit(request, command: "open")

        switch response.result {
        case .ok(.empty):
            return
        case .ok:
            writeStructuredStderr(code: "ipc_error", message: "unexpected response payload")
            throw ExitCode(SolMacExit.ipcError.rawValue)
        case .error(let error):
            try remapServerError(error, command: "open")
        }
    }
}
