// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let raceLog = Logger(subsystem: "app.solstone.observer.spl", category: "race")

struct RaceResult<Value: Sendable>: Sendable {
    let endpoint: TransportEndpoint
    let value: Value
}

struct RaceCoordinator<Value: Sendable>: Sendable {
    private enum Event: Sendable {
        case success(order: Int, endpoint: TransportEndpoint, value: Value)
        case failure(order: Int, error: SessionError)
        case budgetExpired
        case graceExpired
    }

    private let stagger: Duration
    private let loserGrace: Duration
    private let budget: Duration
    private let dial: @Sendable (TransportEndpoint) async throws -> Value
    private let discard: @Sendable (Value) async -> Void

    init(
        stagger: Duration = .milliseconds(50),
        loserGrace: Duration = .milliseconds(250),
        budget: Duration = .seconds(8),
        dial: @escaping @Sendable (TransportEndpoint) async throws -> Value,
        discard: @escaping @Sendable (Value) async -> Void = { _ in }
    ) {
        self.stagger = stagger
        self.loserGrace = loserGrace
        self.budget = budget
        self.dial = dial
        self.discard = discard
    }

    func connect(endpoints: [TransportEndpoint]) async throws -> RaceResult<Value> {
        guard !endpoints.isEmpty else {
            throw SessionError.unreachable
        }

        let sorted = Self.sorted(endpoints)
        raceLog.notice("dial candidates=\(Self.describe(sorted), privacy: .public)")
        guard sorted.count > 1 else {
            let endpoint = sorted[0]
            let startedAt = ContinuousClock.now
            do {
                let value = try await dial(endpoint)
                raceLog.notice("candidate ok endpoint=\(endpoint.logDescription, privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
                raceLog.notice("race winner endpoint=\(endpoint.logDescription, privacy: .public)")
                return RaceResult(endpoint: endpoint, value: value)
            } catch {
                let sessionError = Self.sessionError(from: error)
                raceLog.notice("candidate failed endpoint=\(endpoint.logDescription, privacy: .public) error=\(String(describing: sessionError), privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
                throw sessionError
            }
        }

        return try await withThrowingTaskGroup(of: Event.self, returning: RaceResult<Value>.self) { group in
            for (order, endpoint) in sorted.enumerated() {
                group.addTask {
                    if order > 0 {
                        do {
                            try await Task.sleep(for: stagger * order)
                        } catch {
                            return .failure(order: order, error: .unreachable)
                        }
                    }

                    let startedAt = ContinuousClock.now
                    do {
                        let value = try await dial(endpoint)
                        raceLog.notice("candidate ok endpoint=\(endpoint.logDescription, privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
                        return .success(order: order, endpoint: endpoint, value: value)
                    } catch {
                        let sessionError = Self.sessionError(from: error)
                        raceLog.notice("candidate failed endpoint=\(endpoint.logDescription, privacy: .public) error=\(String(describing: sessionError), privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
                        return .failure(order: order, error: sessionError)
                    }
                }
            }

            group.addTask {
                do {
                    try await Task.sleep(for: budget)
                } catch {
                    return .budgetExpired
                }
                return .budgetExpired
            }

            var failures = 0
            var successes: [(order: Int, endpoint: TransportEndpoint, value: Value)] = []
            var graceStarted = false
            var sawRevocation = false
            var sawNotEntitled = false
            var sawTokenExpired = false

            while let event = try await group.next() {
                switch event {
                case .success(let order, let endpoint, let value):
                    successes.append((order, endpoint, value))
                    if !graceStarted {
                        graceStarted = true
                        group.addTask {
                            do {
                                try await Task.sleep(for: loserGrace)
                            } catch {
                                return .graceExpired
                            }
                            return .graceExpired
                        }
                    }

                case .failure(_, let error):
                    failures += 1
                    if error == .revoked {
                        sawRevocation = true
                    }
                    if error == .notEntitled {
                        sawNotEntitled = true
                    }
                    if error == .tokenExpired {
                        sawTokenExpired = true
                    }
                    if failures == sorted.count, successes.isEmpty {
                        group.cancelAll()
                        await drainDiscarding(&group)
                        throw Self.aggregateFailure(
                            sawRevocation: sawRevocation,
                            sawNotEntitled: sawNotEntitled,
                            sawTokenExpired: sawTokenExpired
                        )
                    }

                case .budgetExpired:
                    if successes.isEmpty {
                        group.cancelAll()
                        await drainDiscarding(&group)
                        throw Self.aggregateFailure(
                            sawRevocation: sawRevocation,
                            sawNotEntitled: sawNotEntitled,
                            sawTokenExpired: sawTokenExpired
                        )
                    }

                case .graceExpired:
                    guard let winner = successes.min(by: { $0.order < $1.order }) else {
                        group.cancelAll()
                        await drainDiscarding(&group)
                        throw Self.aggregateFailure(
                            sawRevocation: sawRevocation,
                            sawNotEntitled: sawNotEntitled,
                            sawTokenExpired: sawTokenExpired
                        )
                    }
                    group.cancelAll()
                    await discardCollectedLosers(successes, winnerOrder: winner.order)
                    await drainDiscarding(&group)
                    raceLog.notice("race winner endpoint=\(winner.endpoint.logDescription, privacy: .public)")
                    return RaceResult(endpoint: winner.endpoint, value: winner.value)
                }
            }

            guard let winner = successes.min(by: { $0.order < $1.order }) else {
                throw Self.aggregateFailure(
                    sawRevocation: sawRevocation,
                    sawNotEntitled: sawNotEntitled,
                    sawTokenExpired: sawTokenExpired
                )
            }
            await discardCollectedLosers(successes, winnerOrder: winner.order)
            raceLog.notice("race winner endpoint=\(winner.endpoint.logDescription, privacy: .public)")
            return RaceResult(endpoint: winner.endpoint, value: winner.value)
        }
    }

    private func drainDiscarding(_ group: inout ThrowingTaskGroup<Event, any Error>) async {
        while let event = try? await group.next() {
            if case .success(_, _, let value) = event {
                await discard(value)
            }
        }
    }

    private func discardCollectedLosers(
        _ successes: [(order: Int, endpoint: TransportEndpoint, value: Value)],
        winnerOrder: Int
    ) async {
        for success in successes where success.order != winnerOrder {
            await discard(success.value)
        }
    }

    static func sorted(_ endpoints: [TransportEndpoint]) -> [TransportEndpoint] {
        endpoints.enumerated()
            .sorted { lhs, rhs in
                let leftRank = rank(lhs.element)
                let rightRank = rank(rhs.element)
                if leftRank == rightRank {
                    return lhs.offset < rhs.offset
                }
                return leftRank < rightRank
            }
            .map(\.element)
    }

    private static func rank(_ endpoint: TransportEndpoint) -> Int {
        switch endpoint {
        case .lan(let host, _, _, _):
            if TunnelAddressClassifier.isRFC1918IPv4Literal(host), !endpoint.unpinnedInterface {
                return 0
            }
            if TunnelAddressClassifier.isIPv6ULA(host) {
                return 1
            }
            if TunnelAddressClassifier.isRFC1918IPv4Literal(host), endpoint.unpinnedInterface {
                return 3
            }
            return 2
        case .relay:
            return 4
        }
    }

    private static func describe(_ endpoints: [TransportEndpoint]) -> String {
        endpoints.map(\.logDescription).joined(separator: ", ")
    }

    private static func sessionError(from error: any Error) -> SessionError {
        if let sessionError = error as? SessionError {
            return sessionError
        }
        if let dialError = error as? DialError,
           dialError == .relayUnauthorized || dialError == .relayTokenExpired {
            return .tokenExpired
        }
        if let dialError = error as? DialError,
           dialError == .relayNotEntitled {
            return .notEntitled
        }
        if let tlsError = error as? InnerTLSError {
            return .tlsFailed(String(describing: tlsError))
        }
        return .unreachable
    }

    private static func aggregateFailure(
        sawRevocation: Bool,
        sawNotEntitled: Bool,
        sawTokenExpired: Bool
    ) -> SessionError {
        if sawRevocation {
            return .revoked
        }
        if sawNotEntitled {
            return .notEntitled
        }
        if sawTokenExpired {
            return .tokenExpired
        }
        return .unreachable
    }
}

private func * (duration: Duration, multiplier: Int) -> Duration {
    let components = duration.components
    let milliseconds = Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    return .milliseconds(milliseconds * multiplier)
}

private extension Duration {
    var milliseconds: Int {
        let components = self.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
