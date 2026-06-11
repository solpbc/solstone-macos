import Foundation
@testable import solstone

final class FakeObserverRegistrar: @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<String, ObserverRegistrationFailure>
    private let delay: Duration
    private var descriptors: [ObserverRegistrationDescriptor] = []

    init(
        result: Result<String, ObserverRegistrationFailure> = .success("observer-key"),
        delay: Duration = .zero
    ) {
        self.result = result
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
        return result
    }

    private func record(_ descriptor: ObserverRegistrationDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        descriptors.append(descriptor)
    }
}
