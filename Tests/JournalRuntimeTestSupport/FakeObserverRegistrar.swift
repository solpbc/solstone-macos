import Foundation
import JournalRuntime

public final class FakeObserverRegistrar: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ObserverRegistration, ObserverRegistrationFailure>]
    private let fallbackResult: Result<ObserverRegistration, ObserverRegistrationFailure>
    private let delay: Duration
    private var descriptors: [ObserverRegistrationDescriptor] = []

    public init(
        result: Result<ObserverRegistration, ObserverRegistrationFailure> = .success(ObserverRegistration(key: "observer-key", name: "observer-name")),
        delay: Duration = .zero
    ) {
        self.results = [result]
        self.fallbackResult = result
        self.delay = delay
    }

    public init(
        results: [Result<ObserverRegistration, ObserverRegistrationFailure>],
        delay: Duration = .zero
    ) {
        self.results = results
        self.fallbackResult = results.last ?? .success(ObserverRegistration(key: "observer-key", name: "observer-name"))
        self.delay = delay
    }

    public var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.count
    }

    public var lastDescriptor: ObserverRegistrationDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.last
    }

    public func register(_ descriptor: ObserverRegistrationDescriptor) async -> Result<ObserverRegistration, ObserverRegistrationFailure> {
        record(descriptor)
        if delay != .zero {
            try? await Task.sleep(for: delay)
        }
        return nextResult()
    }

    private func record(_ descriptor: ObserverRegistrationDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        descriptors.append(descriptor)
    }

    private func nextResult() -> Result<ObserverRegistration, ObserverRegistrationFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else {
            return fallbackResult
        }
        return results.removeFirst()
    }
}
