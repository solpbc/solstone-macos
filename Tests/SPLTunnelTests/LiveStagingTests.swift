// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
//
// Live staging dial test. Env-gated via SPL_LIVE_STAGING=1.
//
// OPERATOR PRECONDITIONS:
//   1. A real spl/pl pairing must already be in the login keychain (run `sol-mac spl pair`).
//   2. Network access to spl-relay-staging.jer-3f2.workers.dev must work.
//   3. The home device must be online and accepting connections.
//   4. Run from an interactive shell - keychain prompts may appear.

import Foundation
import Testing
@testable import SPLTunnel

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SPL_LIVE_STAGING"] == "1"))
struct LiveStagingTests {
    @Test func dialPairedHomeStatusEndpoint() async throws {
        let pairing = try #require(try SPLKeychain.load())
        let tunnel = TunnelSession(pairing: pairing)
        let recorder = LiveStateRecorder()
        let observation = observeLive(session: tunnel, recorder: recorder)

        await tunnel.connect()
        try await waitForLive {
            await recorder.states.contains { state in
                if case .connected = state {
                    return true
                }
                return false
            }
        }

        let stream = try await tunnel.openStream()
        let request = "GET /app/link/api/status HTTP/1.1\r\nHost: \(pairing.homeLabel)\r\nConnection: close\r\n\r\n"
        try await stream.write(Data(request.utf8))
        try await stream.close()
        let response = try await readLiveResponse(from: await stream.inbound)
        #expect(response.statusLine.contains("200"))
        let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(json["status"] != nil)

        await tunnel.disconnect()
        observation.cancel()
    }
}

private actor LiveStateRecorder {
    private var values: [TunnelState] = []

    var states: [TunnelState] {
        values
    }

    func append(_ state: TunnelState) {
        values.append(state)
    }
}

private func observeLive(session: TunnelSession, recorder: LiveStateRecorder) -> Task<Void, Never> {
    Task {
        for await state in session.stateUpdates {
            await recorder.append(state)
        }
    }
}

private func waitForLive(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw LiveStagingError.timeout
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
    case timeout
}
