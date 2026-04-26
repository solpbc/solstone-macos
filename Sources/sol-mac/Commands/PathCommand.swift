import ArgumentParser
import Foundation
import SolstoneCore

struct PathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "show common solstone paths."
    )

    func run() async throws {
        print("app=/Applications/solstone.app")
        print("captures=~/Library/Application Support/Solstone/captures/")
        print("config=~/Library/Preferences/app.solstone.observer.plist")
        print("logs=subsystem == \"app.solstone.observer\"")
    }
}
