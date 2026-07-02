// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SPLTunnel

@Suite("LiveHarnessContract")
struct LiveHarnessContractTests {
    @Test func missingPairURLThrowsForAbsentEmptyAndWhitespace() {
        for env in [
            [:],
            ["SPL_PAIR_URL": ""],
            ["SPL_PAIR_URL": " \n\t "],
        ] {
            #expect {
                _ = try parseLiveEnv(env)
            } throws: { error in
                guard case LiveEnvError.missingPairURL = error else { return false }
                return true
            }
        }
    }

    @Test func rejectedPairURLWrapsTypedReason() {
        #expect {
            _ = try parseLiveEnv(["SPL_PAIR_URL": "https://evil.example/p#\(Self.canonicalBlob)"])
        } throws: { error in
            guard case LiveEnvError.pairURLRejected(.wrongHost("evil.example")) = error else { return false }
            return true
        }
    }

    @Test func validPairURLUsesDefaultStagingRelay() throws {
        let config = try parseLiveEnv(["SPL_PAIR_URL": Self.canonicalPairURL])

        #expect(config.relayEndpoint.absoluteString == LiveHarnessDefaults.stagingRelayEndpoint)
        #expect(config.forceRelay == false)
    }

    @Test func relayEndpointOverrideIsRespected() throws {
        let config = try parseLiveEnv([
            "SPL_PAIR_URL": Self.canonicalPairURL,
            "SPL_RELAY_ENDPOINT": "https://relay.example.test/base",
        ])

        #expect(config.relayEndpoint.absoluteString == "https://relay.example.test/base")
    }

    @Test func malformedRelayEndpointThrows() {
        #expect {
            _ = try parseLiveEnv([
                "SPL_PAIR_URL": Self.canonicalPairURL,
                "SPL_RELAY_ENDPOINT": "ht tp://bad",
            ])
        } throws: { error in
            guard case LiveEnvError.malformedRelayEndpoint("ht tp://bad") = error else { return false }
            return true
        }
    }

    @Test func forceRelayFlagIsOptIn() throws {
        let absent = try parseLiveEnv(["SPL_PAIR_URL": Self.canonicalPairURL])
        let enabled = try parseLiveEnv([
            "SPL_PAIR_URL": Self.canonicalPairURL,
            "SPL_FORCE_RELAY": "1",
        ])

        #expect(absent.forceRelay == false)
        #expect(enabled.forceRelay == true)
    }

    @Test func relayOnlyCandidatesKeepRelayAndExcludeLAN() throws {
        let endpoints = try relayOnlyCandidates(for: Self.pairing(
            relayEnrollment: .enrolled(deviceToken: "tok", expiresAt: nil),
            localEndpoints: [LocalEndpoint(host: "192.168.1.2", port: 7777, scope: "")]
        ))

        #expect(endpoints.count == 1)
        guard case .relay(let endpoint, let instanceID, let deviceToken) = try #require(endpoints.first) else {
            Issue.record("Expected one relay endpoint")
            return
        }
        #expect(endpoint.absoluteString == LiveHarnessDefaults.stagingRelayEndpoint)
        #expect(instanceID == "instance-live-test")
        #expect(deviceToken == "tok")
    }

    @Test func relayOnlyCandidatesFailWhenEnrollmentUnavailableWithoutLANFallback() {
        #expect {
            _ = try relayOnlyCandidates(for: Self.pairing(
                relayEnrollment: .unavailable,
                localEndpoints: [LocalEndpoint(host: "192.168.1.2", port: 7777, scope: "")]
            ))
        } throws: { error in
            guard case RelayPreconditionError.relayEnrollmentUnavailable = error else { return false }
            return true
        }
    }

    @Test func relayOnlyCandidatesFailWhenFilterIsEmpty() {
        #expect {
            _ = try relayOnlyCandidates(for: Self.pairing(
                relayEnrollment: .enrolled(deviceToken: " ", expiresAt: nil),
                localEndpoints: [LocalEndpoint(host: "192.168.1.2", port: 7777, scope: "")]
            ))
        } throws: { error in
            guard case RelayPreconditionError.noRelayCandidates = error else { return false }
            return true
        }
    }

    private static let canonicalBlob = "0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF"
    private static let canonicalPairURL = "https://go.solstone.app/p#\(canonicalBlob)"

    private static func pairing(
        relayEnrollment: RelayEnrollment,
        relayEndpoint: String = LiveHarnessDefaults.stagingRelayEndpoint,
        localEndpoints: [LocalEndpoint]
    ) -> StoredPairing {
        StoredPairing(
            instanceID: "instance-live-test",
            homeLabel: "live home",
            relayEndpoint: relayEndpoint,
            fingerprint: "sha256:live",
            clientCertPEM: "client cert",
            clientKeyPEM: "client key",
            caChainPEM: "ca chain",
            relayEnrollment: relayEnrollment,
            localEndpoints: localEndpoints,
            pairedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
