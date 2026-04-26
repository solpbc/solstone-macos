import ArgumentParser
import Foundation
import SolstoneCore

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "show cli and app versions."
    )

    func run() async throws {
        print("sol-mac \(CLIVersion.version) (\(CLIVersion.build))")

        let request = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .versionInfo
        )

        guard let response = try? await SolMacClient.send(
            request,
            connectTimeout: .milliseconds(500),
            requestTimeout: .seconds(1)
        ) else {
            return
        }

        guard response.serverProtocolVersion == SolMacIPCConstants.currentProtocolVersion else {
            return
        }

        switch response.result {
        case .ok(.versionInfo(let info)):
            print("solstone \(info.appVersion) (\(info.appBuild))")
        default:
            break
        }
    }
}
