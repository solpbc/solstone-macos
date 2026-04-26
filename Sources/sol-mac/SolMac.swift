import ArgumentParser
import Foundation

@main
struct SolMac: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sol-mac",
        abstract: "command-line interface for solstone.",
        subcommands: [
            StatusCommand.self,
            VersionCommand.self,
            PathCommand.self,
            DiagnoseCommand.self,
            ConfigCommand.self,
            StartCommand.self,
            StopCommand.self,
            PauseCommand.self,
            UnpauseCommand.self,
            SyncCommand.self,
            OpenCommand.self,
            LogsCommand.self,
            InternalPing.self,
        ]
    )

    mutating func run() async throws {
        print(Self.helpMessage())
    }
}
