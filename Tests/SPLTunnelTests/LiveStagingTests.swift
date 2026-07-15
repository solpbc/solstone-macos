// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
//
// Live staging dial harness. Operator-direct only; never runs in CI because the
// suite is gated off unless SPL_LIVE=1.
//
// ENV:
//   SPL_LIVE=1 gates the suite on.
//   SPL_PAIR_URL is a required fresh one-shot pair link.
//   SPL_RELAY_ENDPOINT overrides the relay endpoint; default:
//     https://spl-relay-staging.jer-3f2.workers.dev
//   SPL_FORCE_RELAY=1 forces relay-only candidates and asserts relay transport.
//
// The one-shot pair link is consumed even on a failed dial. Every retry needs a
// fresh SPL_PAIR_URL.
//
// This registers a device labeled "solstone-live-harness"; prune it server-side
// in convey after runs.
//
// No keychain prompts: pairing is held in memory only and never persisted.
//
// Example:
//   SPL_LIVE=1 SPL_PAIR_URL='https://go.solstone.app/p#…' [SPL_FORCE_RELAY=1] swift test --filter LiveStaging

import Foundation
import Testing
import SPLTunnel

@Suite(.disabled(if: ProcessInfo.processInfo.environment["SPL_LIVE"] != "1",
                 "set SPL_LIVE=1 to run the live staging dial harness"))
struct LiveStagingTests {
    static let deviceLabel = "solstone-live-harness"

    @Test func dialStatusEndpoint() async throws {
        let config = try parseLiveEnv(ProcessInfo.processInfo.environment)
        let pairing = try await PairClient().pair(
            pairURL: config.pairURL,
            deviceLabel: Self.deviceLabel,
            relayEndpoint: config.relayEndpoint
        )
        let endpoints: [TransportEndpoint]
        if config.forceRelay {
            endpoints = try relayOnlyCandidates(for: pairing)
        } else {
            endpoints = TransportEndpoint.candidates(for: pairing)
        }
        let tunnel = TunnelSession(pairing: pairing)
        let via = try await tunnel.connect(endpoints: endpoints)

        do {
            let stream = try await tunnel.openStream()
            let request = "GET /app/network/api/status HTTP/1.1\r\nHost: \(pairing.homeLabel)\r\nConnection: close\r\n\r\n"
            try await stream.write(Data(request.utf8))
            try await stream.close()
            let response = try await readLiveResponse(from: await stream.inbound)
            #expect(response.statusLine.contains("200"))
            let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            _ = try #require(json["posture"])

            if config.forceRelay {
                let connectedViaRelay: Bool
                if case .relay = via {
                    connectedViaRelay = true
                } else {
                    connectedViaRelay = false
                }
                #expect(connectedViaRelay)
            } else {
                print("LiveStagingTests connected via \(via)")
            }

            await tunnel.disconnect()
        } catch {
            await tunnel.disconnect()
            throw error
        }
    }
}

private func readLiveResponse(from inbound: AsyncThrowingStream<Data, Error>) async throws -> (statusLine: String, body: Data) {
    var data = Data()
    for try await chunk in inbound {
        data.append(chunk)
    }
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
          let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8),
          let statusLine = headerText.components(separatedBy: "\r\n").first else {
        throw LiveStagingError.invalidResponse
    }
    return (statusLine, Data(data[separator.upperBound...]))
}

private enum LiveStagingError: Error {
    case invalidResponse
}
