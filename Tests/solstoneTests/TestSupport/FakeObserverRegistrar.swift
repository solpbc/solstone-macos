import Foundation
@testable import solstone

final class FakeObserverRegistrar: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, ObserverRegistrationFailure>]
    private let fallbackResult: Result<String, ObserverRegistrationFailure>
    private let delay: Duration
    private var descriptors: [ObserverRegistrationDescriptor] = []

    init(
        result: Result<String, ObserverRegistrationFailure> = .success("observer-key"),
        delay: Duration = .zero
    ) {
        self.results = [result]
        self.fallbackResult = result
        self.delay = delay
    }

    init(
        results: [Result<String, ObserverRegistrationFailure>],
        delay: Duration = .zero
    ) {
        self.results = results
        self.fallbackResult = results.last ?? .success("observer-key")
        self.delay = delay
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.count
    }

    var lastDescriptor: ObserverRegistrationDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.last
    }

    func register(_ descriptor: ObserverRegistrationDescriptor) async -> Result<String, ObserverRegistrationFailure> {
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

    private func nextResult() -> Result<String, ObserverRegistrationFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else {
            return fallbackResult
        }
        return results.removeFirst()
    }
}
