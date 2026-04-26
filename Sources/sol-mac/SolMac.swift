import ArgumentParser
import SolstoneCore

@main
struct SolMac: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sol-mac",
        subcommands: [InternalPing.self]
    )

    mutating func run() async throws {
        print("sol-mac stub — commands wire up in Lode 3")
    }
}
