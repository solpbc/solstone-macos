import Foundation

public enum InProgressUpgradePhase: String, Codable, Sendable {
    case staging
    case stoppingOld
    case settingUp
    case activating
    case startingService
    case registering
}

public struct InProgressUpgradeMarker: Codable, Equatable, Sendable {
    public let upgradeID: String
    public let pinned: String
    public let oldVersion: String
    public let oldSolPath: String
    public let resolvedJournalPath: String
    public let stagedRuntimeID: String
    public let stagedRuntimePath: String
    public let phase: InProgressUpgradePhase

    public init(
        upgradeID: String,
        pinned: String,
        oldVersion: String,
        oldSolPath: String,
        resolvedJournalPath: String,
        stagedRuntimeID: String,
        stagedRuntimePath: String,
        phase: InProgressUpgradePhase
    ) {
        self.upgradeID = upgradeID
        self.pinned = pinned
        self.oldVersion = oldVersion
        self.oldSolPath = oldSolPath
        self.resolvedJournalPath = resolvedJournalPath
        self.stagedRuntimeID = stagedRuntimeID
        self.stagedRuntimePath = stagedRuntimePath
        self.phase = phase
    }
}

public protocol InProgressUpgradeMarkerStoring: Sendable {
    func load() -> InProgressUpgradeMarker?
    func save(_ marker: InProgressUpgradeMarker)
    func clear()
}

public final class UserDefaultsInProgressUpgradeMarkerStore: InProgressUpgradeMarkerStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "SolstoneInProgressUpgradeMarker") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> InProgressUpgradeMarker? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(InProgressUpgradeMarker.self, from: data)
    }

    public func save(_ marker: InProgressUpgradeMarker) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

internal final class InMemoryInProgressUpgradeMarkerStore: InProgressUpgradeMarkerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var marker: InProgressUpgradeMarker?
    private var _clearCallCount = 0

    init(marker: InProgressUpgradeMarker? = nil) {
        self.marker = marker
    }

    func load() -> InProgressUpgradeMarker? {
        lock.withLock { marker }
    }

    func save(_ marker: InProgressUpgradeMarker) {
        lock.withLock {
            self.marker = marker
        }
    }

    func clear() {
        lock.withLock {
            marker = nil
            _clearCallCount += 1
        }
    }

    var clearCallCount: Int {
        lock.withLock { _clearCallCount }
    }
}
