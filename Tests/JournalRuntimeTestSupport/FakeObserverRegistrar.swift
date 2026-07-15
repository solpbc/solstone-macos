import Foundation
import JournalMarkKit

public final class FakeObserverRegistrar: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ObserverRegistration, ObserverRegistrationFailure>]
    private let fallbackResult: Result<ObserverRegistration, ObserverRegistrationFailure>
    private let delay: Duration
    private var descriptors: [ObserverRegistrationDescriptor] = []
    private var recordedBaseURLs: [String] = []

    public init(
        result: Result<ObserverRegistration, ObserverRegistrationFailure> = .success(ObserverRegistration(key: "observer-key", streamName: "observer-stream")),
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
        self.fallbackResult = results.last ?? .success(ObserverRegistration(key: "observer-key", streamName: "observer-stream"))
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

    public var lastBaseURL: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedBaseURLs.last
    }

    public var baseURLs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedBaseURLs
    }

    public func register(
        baseURL: String,
        descriptor: ObserverRegistrationDescriptor
    ) async -> Result<ObserverRegistration, ObserverRegistrationFailure> {
        record(baseURL: baseURL, descriptor: descriptor)
        if delay != .zero {
            try? await Task.sleep(for: delay)
        }
        return nextResult()
    }

    private func record(baseURL: String, descriptor: ObserverRegistrationDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        recordedBaseURLs.append(baseURL)
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
