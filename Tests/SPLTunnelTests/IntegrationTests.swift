// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
//
// Integration tests for the spl/pl client stack. Env-gated via SPL_INTEGRATION=1.
// Tests use SPLKeychain directly, which requires login-keychain access. On non-interactive
// CI/SSH shells this surfaces as errSecInteractionNotAllowed (-25308). Run from an
// interactive shell (tmux pane is fine) when invoking `make integration-test`.
//
// Relay-path coverage: WS /session/dial is NOT exercised here. Real-relay logic is
// covered by spl-relay's own tests + LiveStagingTests for the CF Worker bridging.

import Crypto
import Darwin.Mach
import Foundation
import Security
import Testing
@testable import SPLTunnel

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SPL_INTEGRATION"] == "1"))
struct IntegrationTests {
    @Test func endToEndPairConnectSmallRequestUploadDisconnect() async throws {
        try await withMockEnv { env in
            let session = URLSession(configuration: .ephemeral)
            let statusURL = URL(string: "http://127.0.0.1:\(env.proxyPort)/app/link/api/status")!
            let (statusData, statusResponse) = try await session.data(from: statusURL)
            let statusHTTP = try #require(statusResponse as? HTTPURLResponse)
            #expect(statusHTTP.statusCode == 200)
            let statusJSON = try jsonObject(statusData)
            #expect(statusJSON["status"] as? String == "ok")
            #expect(statusJSON["echo"] as? String == "mock-home")

            let payload = randomData(count: 1_024)
            let upload = makeMultipartUpload(payload: payload, port: env.proxyPort)
            let (uploadData, uploadResponse) = try await session.upload(for: upload.request, from: upload.body)
            let uploadHTTP = try #require(uploadResponse as? HTTPURLResponse)
            #expect(uploadHTTP.statusCode == 200)
            let uploadJSON = try jsonObject(uploadData)
            #expect(uploadJSON["received_bytes"] as? Int == payload.count)
            #expect(firstFileSHA256(in: uploadJSON) == sha256Hex(payload))

            await env.tunnel.disconnect()
        }
    }

    @Test func largeUploadIsByteEqualAndBackpressureBounded() async throws {
        try await withMockEnv { env in
            let session = URLSession(configuration: .ephemeral)
            let payload = randomData(count: 10 * 1_024 * 1_024)
            let upload = makeMultipartUpload(payload: payload, port: env.proxyPort)
            let before = residentSetSize()
            let (data, response) = try await session.upload(for: upload.request, from: upload.body)
            let after = residentSetSize()

            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            let json = try jsonObject(data)
            #expect(json["received_bytes"] as? Int == payload.count)
            #expect(firstFileSHA256(in: json) == sha256Hex(payload))
            let growth = after > before ? after - before : 0
            #expect(growth < 16 * 1_024 * 1_024)

            await env.tunnel.disconnect()
        }
    }

    @Test func threeConcurrentUploadsCompleteIndependently() async throws {
        try await withMockEnv { env in
            let sizes = [1, 2, 4].map { $0 * 1_024 * 1_024 }
            let proxyPort = env.proxyPort
            try await withThrowingTaskGroup(of: Void.self) { group in
                for size in sizes {
                    group.addTask {
                        let session = URLSession(configuration: .ephemeral)
                        let payload = randomData(count: size)
                        let upload = makeMultipartUpload(payload: payload, port: proxyPort)
                        let (data, response) = try await session.upload(for: upload.request, from: upload.body)
                        let http = try #require(response as? HTTPURLResponse)
                        #expect(http.statusCode == 200)
                        let json = try jsonObject(data)
                        #expect(json["received_bytes"] as? Int == payload.count)
                        #expect(firstFileSHA256(in: json) == sha256Hex(payload))
                    }
                }
                try await group.waitForAll()
            }

            await env.tunnel.disconnect()
        }
    }

    @Test func reconnectAfterDropTransitionsConnectingThenConnected() async throws {
        try await withMockEnv { env in
            let initialConnectedCount = await env.stateRecorder.connectedCount

            await env.mockHome.stopTLSMuxListener()
            try await waitUntil(timeout: .seconds(15)) {
                await env.stateRecorder.states.contains { state in
                    if case .connecting = state {
                        return true
                    }
                    if case .failed = state {
                        return true
                    }
                    return false
                }
            }

            _ = try await env.mockHome.startTLSMuxListener()
            try await waitUntil(timeout: .seconds(10)) {
                await env.stateRecorder.connectedCount > initialConnectedCount
            }

            await env.tunnel.disconnect()
        }
    }
}

private struct MockEnv {
    let mockHome: MockHome
    let mockRelay: MockRelay
    let tunnel: TunnelSession
    let proxy: LoopbackProxy
    let proxyPort: UInt16
    let stateRecorder: IntegrationStateRecorder
    let stateObservation: Task<Void, Never>
    let previousPairing: StoredPairing?
}

private func withMockEnv<T>(_ body: (MockEnv) async throws -> T) async throws -> T {
    let env = try await setUpMockEnv()
    do {
        let result = try await body(env)
        await tearDownMockEnv(env)
        return result
    } catch {
        await tearDownMockEnv(env)
        throw error
    }
}

private func setUpMockEnv() async throws -> MockEnv {
    let previousPairing = try SPLKeychain.load()
    var mockHome: MockHome?
    var mockRelay: MockRelay?
    var tunnel: TunnelSession?
    var proxy: LoopbackProxy?
    var observation: Task<Void, Never>?

    do {
        let home = try MockHome()
        mockHome = home
        _ = try await home.startTLSMuxListener()
        _ = try await home.startPairServer()
        let relay = try MockRelay()
        mockRelay = relay
        let relayEndpoint = try await relay.start()
        let pairNonce = try await home.mintPairNonce()
        let pairing = try await PairClient().pair(
            pairURL: pairNonce.pairURL,
            deviceLabel: "test",
            relayEndpoint: relayEndpoint
        )
        try SPLKeychain.save(pairing)

        let session = TunnelSession(pairing: pairing)
        tunnel = session
        let recorder = IntegrationStateRecorder()
        let stateObservation = observe(session: session, recorder: recorder)
        observation = stateObservation
        try await session.connect(endpoints: TransportEndpoint.candidates(for: pairing))
        try await waitUntil(timeout: .seconds(10)) {
            await recorder.states.contains { state in
                if case .connected = state {
                    return true
                }
                return false
            }
        }

        let loopback = LoopbackProxy(tunnel: session)
        proxy = loopback
        let proxyPort = try await loopback.start()
        return MockEnv(
            mockHome: home,
            mockRelay: relay,
            tunnel: session,
            proxy: loopback,
            proxyPort: proxyPort,
            stateRecorder: recorder,
            stateObservation: stateObservation,
            previousPairing: previousPairing
        )
    } catch {
        observation?.cancel()
        await proxy?.stop()
        await tunnel?.disconnect()
        await mockRelay?.stop()
        await mockHome?.stop()
        try? restoreKeychain(previousPairing)
        throw error
    }
}

private func tearDownMockEnv(_ env: MockEnv) async {
    env.stateObservation.cancel()
    await env.proxy.stop()
    await env.tunnel.disconnect()
    await env.mockRelay.stop()
    await env.mockHome.stop()
    try? restoreKeychain(env.previousPairing)
}

private func restoreKeychain(_ pairing: StoredPairing?) throws {
    if let pairing {
        try SPLKeychain.save(pairing)
    } else {
        try SPLKeychain.delete()
    }
}

private func observe(session: TunnelSession, recorder: IntegrationStateRecorder) -> Task<Void, Never> {
    Task {
        for await state in session.stateUpdates {
            await recorder.append(state)
        }
    }
}

private actor IntegrationStateRecorder {
    private var values: [TunnelState] = []

    var states: [TunnelState] {
        values
    }

    var connectedCount: Int {
        values.filter { state in
            if case .connected = state {
                return true
            }
            return false
        }.count
    }

    func append(_ state: TunnelState) {
        values.append(state)
    }
}

private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw IntegrationTestError.timeout
}

private func makeMultipartUpload(payload: Data, port: UInt16) -> (request: URLRequest, body: Data) {
    let boundary = "spl-boundary-\(UUID().uuidString.lowercased())"
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"payload.bin\"\r\n".utf8))
    body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(payload)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/app/observer/ingest")!)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    return (request, body)
}

private func randomData(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return Data(bytes)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func firstFileSHA256(in json: [String: Any]) -> String? {
    guard let files = json["files"] as? [[String: Any]] else {
        return nil
    }
    return files.first?["sha256"] as? String
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func residentSetSize() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else {
        return 0
    }
    return UInt64(info.resident_size)
}

private enum IntegrationTestError: Error {
    case timeout
}
