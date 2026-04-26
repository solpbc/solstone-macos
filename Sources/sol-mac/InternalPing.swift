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
            FileHandle.standardError.write(Data("unexpected response\n".utf8))
            throw ExitCode.failure
        case .error(let error):
            if let hint = error.hint {
                print("\(error.code): \(error.message) (\(hint))")
            } else {
                print("\(error.code): \(error.message)")
            }
        }
    }
}
