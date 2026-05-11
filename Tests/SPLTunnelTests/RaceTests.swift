// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SPLTunnel

@Suite("RaceCoordinator")
struct RaceTests {
    @Test func sortsULAThenRFC1918ThenOtherDirectThenRelay() {
        let relay = TransportEndpoint.relay(
            endpoint: URL(string: "wss://relay.example/session")!,
            instanceID: "instance",
            deviceToken: "token"
        )
        let endpoints: [TransportEndpoint] = [
            relay,
            .lan(host: "203.0.113.10", port: 443, scope: "public"),
            .lan(host: "192.168.1.10", port: 443, scope: "local"),
            .lan(host: "fd12:3456::1", port: 443, scope: "ula"),
        ]

        #expect(RaceCoordinator<Int>.sorted(endpoints) == [
            .lan(host: "fd12:3456::1", port: 443, scope: "ula"),
            .lan(host: "192.168.1.10", port: 443, scope: "local"),
            .lan(host: "203.0.113.10", port: 443, scope: "public"),
            relay,
        ])
    }

    @Test func ulaWinsOverRFC1918WithStaggerAndSimilarHandshakeTime() async throws {
        let ula = TransportEndpoint.lan(host: "fd12:3456::1", port: 443, scope: "ula")
        let rfc1918 = TransportEndpoint.lan(host: "192.168.1.10", port: 443, scope: "local")
        let coordinator = RaceCoordinator<TransportEndpoint>(
            stagger: .milliseconds(20),
            loserGrace: .milliseconds(10),
            budget: .milliseconds(200)
        ) { endpoint in
            try await Task.sleep(for: .milliseconds(15))
            return endpoint
        }

        let result = try await coordinator.connect(endpoints: [rfc1918, ula])

        #expect(result.endpoint == ula)
        #expect(result.value == ula)
    }

    @Test func loserGraceLetsSlowerBetterCandidateWin() async throws {
        let direct = TransportEndpoint.lan(host: "10.0.0.5", port: 443, scope: "local")
        let relay = TransportEndpoint.relay(
            endpoint: URL(string: "wss://relay.example/session")!,
            instanceID: "instance",
            deviceToken: "token"
        )
        let coordinator = RaceCoordinator<TransportEndpoint>(
            stagger: .milliseconds(1),
            loserGrace: .milliseconds(50),
            budget: .milliseconds(200)
        ) { endpoint in
            switch endpoint {
            case .lan:
                try await Task.sleep(for: .milliseconds(30))
            case .relay:
                try await Task.sleep(for: .milliseconds(1))
            }
            return endpoint
        }

        let result = try await coordinator.connect(endpoints: [relay, direct])

        #expect(result.endpoint == direct)
    }

    @Test func budgetAbortThrowsUnreachable() async {
        let coordinator = RaceCoordinator<Int>(
            stagger: .milliseconds(1),
            loserGrace: .milliseconds(1),
            budget: .milliseconds(20)
        ) { _ in
            try await Task.sleep(for: .seconds(1))
            return 1
        }

        await expectSessionError(.unreachable) {
            _ = try await coordinator.connect(endpoints: [
                .lan(host: "10.0.0.5", port: 443, scope: "local"),
                .lan(host: "192.168.1.10", port: 443, scope: "local"),
            ])
        }
    }

    @Test func singleElementBypassesRaceStagger() async throws {
        let endpoint = TransportEndpoint.lan(host: "10.0.0.5", port: 443, scope: "local")
        let startedAt = ContinuousClock.now
        let coordinator = RaceCoordinator<Int>(
            stagger: .milliseconds(500),
            loserGrace: .milliseconds(500),
            budget: .seconds(1)
        ) { _ in 42 }

        let result = try await coordinator.connect(endpoints: [endpoint])
        let elapsed = startedAt.duration(to: .now)

        #expect(result.endpoint == endpoint)
        #expect(result.value == 42)
        #expect(elapsed < .milliseconds(100))
    }

    @Test func allFailuresThrowUnreachable() async {
        let coordinator = RaceCoordinator<Int>(
            stagger: .milliseconds(1),
            loserGrace: .milliseconds(1),
            budget: .milliseconds(200)
        ) { _ in
            throw SessionError.transportFailed("fixture")
        }

        await expectSessionError(.unreachable) {
            _ = try await coordinator.connect(endpoints: [
                .lan(host: "10.0.0.5", port: 443, scope: "local"),
                .lan(host: "192.168.1.10", port: 443, scope: "local"),
            ])
        }
    }

    private func expectSessionError(
        _ expected: SessionError,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as SessionError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got \(error)")
        }
    }
}
