// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network

enum PathInterfaceBucket: Sendable, Equatable {
    case wifi
    case wired
    case cellular
    case other
}

struct NetworkPathStatus: Sendable, Equatable {
    let bucket: PathInterfaceBucket
    let isSatisfied: Bool
    let isExpensive: Bool
    let isConstrained: Bool

    var signature: NetworkPathSignature {
        NetworkPathSignature(bucket: bucket, isSatisfied: isSatisfied)
    }
}

struct NetworkPathSignature: Sendable, Equatable {
    let bucket: PathInterfaceBucket
    let isSatisfied: Bool
}

protocol PathMonitoringSource: AnyObject, Sendable {
    func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void)
    func stop()
}

final class NoopPathMonitoringSource: PathMonitoringSource, @unchecked Sendable {
    func start(onPathChange _: @Sendable @escaping (NetworkPathStatus) -> Void) {}
    func stop() {}
}

private final class NWPathMonitoringSource: PathMonitoringSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.solstone.observer.spl.path-monitor")
    private let lock = NSLock()
    private var monitor: NWPathMonitor?

    func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            onPathChange(NetworkPathStatus(path: path))
        }
        lock.withLock {
            self.monitor = monitor
        }
        monitor.start(queue: queue)
    }

    func stop() {
        let monitor = lock.withLock {
            let monitor = self.monitor
            self.monitor = nil
            return monitor
        }
        monitor?.cancel()
    }
}

@MainActor
final class PathMonitor: Sendable {
    private let source: any PathMonitoringSource
    private var debounceTask: Task<Void, Never>?
    private var generation = 0
    private var lastEmittedSignature: NetworkPathSignature?
    private var pendingSignature: NetworkPathSignature?

    init(source: any PathMonitoringSource = NWPathMonitoringSource()) {
        self.source = source
    }

    func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void) {
        stop()
        let generation = self.generation
        source.start { [weak self] status in
            Task { @MainActor in
                guard let self, self.generation == generation else {
                    return
                }
                self.schedule(status, onPathChange: onPathChange)
            }
        }
    }

    func stop() {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingSignature = nil
        lastEmittedSignature = nil
        source.stop()
    }

    private func schedule(
        _ status: NetworkPathStatus,
        onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void
    ) {
        let signature = status.signature
        guard signature != lastEmittedSignature, signature != pendingSignature else {
            return
        }

        pendingSignature = signature
        debounceTask?.cancel()
        let generation = self.generation
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled, self.generation == generation else {
                return
            }
            self.pendingSignature = nil
            guard signature != self.lastEmittedSignature else {
                return
            }
            self.lastEmittedSignature = signature
            onPathChange(status)
        }
    }
}

private extension NetworkPathStatus {
    init(path: NWPath) {
        self.init(
            bucket: path.interfaceBucket,
            isSatisfied: path.status == .satisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}

private extension NWPath {
    var interfaceBucket: PathInterfaceBucket {
        if usesInterfaceType(.wiredEthernet) {
            return .wired
        }
        if usesInterfaceType(.wifi) {
            return .wifi
        }
        if usesInterfaceType(.cellular) {
            return .cellular
        }
        return .other
    }
}
