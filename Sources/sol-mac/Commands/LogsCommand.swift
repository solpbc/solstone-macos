import ArgumentParser
import Foundation
import SolstoneCore

let logCategoryWhitelist: Set<String> = ["general", "capture", "audio", "upload", "setup", "storage"]

func buildLogsArgv(tail: Bool, category: String?, last: String?) -> [String] {
    var predicate = #"subsystem == "app.solstone.observer""#
    if let category {
        predicate += #" AND category == "\#(category)""#
    }

    if tail {
        return ["stream", "--predicate", predicate, "--level", "debug"]
    }

    return ["show", "--predicate", predicate, "--last", last ?? "1h", "--info", "--debug", "--style", "compact"]
}

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "show solstone logs."
    )

    @Flag(name: .long, help: "stream logs live.")
    var tail: Bool = false

    @Option(name: .long, help: "optional log category.")
    var category: String?

    @Option(name: .long, help: "show logs from the last duration (default: 1h).")
    var last: String?

    func run() async throws {
        if tail, last != nil {
            writeStructuredStderr(code: "invalid_args", message: "--tail and --last are mutually exclusive")
            throw ExitCode(SolMacExit.invalidArgs.rawValue)
        }

        if let category, !logCategoryWhitelist.contains(category) {
            writeStructuredStderr(code: "invalid_args", message: "invalid category: \(category)")
            throw ExitCode(SolMacExit.invalidArgs.rawValue)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = buildLogsArgv(tail: tail, category: category, last: last)
        proc.standardInput = FileHandle.standardInput
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                throw ExitCode(SolMacExit.ipcError.rawValue)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            writeStructuredStderr(code: "ipc_error", message: "failed to run /usr/bin/log: \(error.localizedDescription)")
            throw ExitCode(SolMacExit.ipcError.rawValue)
        }
    }
}
