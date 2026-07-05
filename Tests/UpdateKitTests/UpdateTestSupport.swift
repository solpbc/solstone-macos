import Foundation
import os
import Testing
@testable import UpdateKit

let updateKitTestLog = Logger(subsystem: "app.solstone.tests", category: "updates")
let updateKitTestErrorDomain = "app.solstone.tests.updates"

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.withLock { self.value = value }
    }

    var current: Value? {
        lock.withLock { value }
    }
}

func waitUntil(
    timeout: Duration,
    poll: Duration = .milliseconds(50),
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: poll)
    }
    #expect(await predicate())
}

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
