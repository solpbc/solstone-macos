import Foundation
@testable import solstone

struct IsolatedUserDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() {
        suiteName = "solstone-update-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func clear() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
final class SpyUpdater: SparkleUpdating {
    var automaticallyChecksForUpdates: Bool
    var updateCheckInterval: TimeInterval
    var automaticallyDownloadsUpdates: Bool
    var sessionInProgress: Bool
    var checkForUpdatesCallCount = 0
    var startCallCount = 0
    var startError: Error?

    init(
        automaticallyChecksForUpdates: Bool = true,
        updateCheckInterval: TimeInterval = 86_400,
        automaticallyDownloadsUpdates: Bool = false,
        sessionInProgress: Bool = false
    ) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.updateCheckInterval = updateCheckInterval
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        self.sessionInProgress = sessionInProgress
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }

    func start() throws {
        startCallCount += 1
        if let startError {
            throw startError
        }
    }
}
