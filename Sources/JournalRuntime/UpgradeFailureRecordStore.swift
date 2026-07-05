import Foundation

public protocol UpgradeFailureRecordStoring: Sendable {
    func load() -> UpgradeFailureRecord?
    func save(_ record: UpgradeFailureRecord)
    func clear()
}

public final class UserDefaultsUpgradeFailureRecordStore: UpgradeFailureRecordStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "SolstoneUpgradeFailureRecord") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> UpgradeFailureRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UpgradeFailureRecord.self, from: data)
    }

    public func save(_ record: UpgradeFailureRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

public final class InMemoryUpgradeFailureRecordStore: UpgradeFailureRecordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: UpgradeFailureRecord?
    private var _clearCallCount = 0

    public init(record: UpgradeFailureRecord? = nil) {
        self.record = record
    }

    public func load() -> UpgradeFailureRecord? {
        lock.withLock { record }
    }

    public func save(_ record: UpgradeFailureRecord) {
        lock.withLock {
            self.record = record
        }
    }

    public func clear() {
        lock.withLock {
            record = nil
            _clearCallCount += 1
        }
    }

    public var clearCallCount: Int {
        lock.withLock { _clearCallCount }
    }
}
