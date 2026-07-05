import Foundation
import JournalRuntime
import SolstoneCore

extension AppState: InstallerHost {
    public var installerConfig: AppConfig {
        config
    }

    public func updateInstallerConfig(_ config: AppConfig) {
        updateConfig(config)
    }

    public func notifyInstallerUpgradeStarted() {
        notifyUpgradeStarted()
    }

    public func testInstallerConnection(serverURL: String, serverKey: String) async -> String? {
        await UploadCoordinator.testConnection(serverURL: serverURL, serverKey: serverKey)
    }
}
