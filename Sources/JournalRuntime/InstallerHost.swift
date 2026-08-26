import Foundation
import SolstoneCore

@MainActor
public protocol InstallerHost: AnyObject, Sendable {
    var installerConfig: AppConfig { get }
    func updateInstallerConfig(_ config: AppConfig)
    func notifyInstallerUpgradeStarted()
    func ensureBundledJournalRuntime(journalRoot: URL) async -> Bool
}
