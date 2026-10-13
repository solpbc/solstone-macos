import Foundation
import SolstoneCore

public final class RecordingClassifiedLogSink: ClassifiedLogSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ClassifiedLogEmission] = []

    public init() {}

    public func emit(_ emission: ClassifiedLogEmission) {
        lock.lock()
        storage.append(emission)
        lock.unlock()
    }

    public var emissions: [ClassifiedLogEmission] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
