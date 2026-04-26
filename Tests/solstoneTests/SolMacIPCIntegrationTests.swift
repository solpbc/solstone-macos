// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
@testable import solstone
@testable import sol_mac

@Suite("SolMacIPCIntegration")
@MainActor
struct SolMacIPCIntegrationTests {
    @Test func pingRoundTrip() async throws {
        let socketURL = makeSocketURL()
        let service = startService(at: socketURL)
        defer { service.stop() }

        let response = try await SolMacClient.send(
            IPCRequest(
                id: UUID(),
                protocolVersion: SolMacIPCConstants.currentProtocolVersion,
                command: .ping
            ),
            socketURL: socketURL
        )

        guard case .ok(.pong) = response.result else {
            Issue.record("Expected pong response")
            return
        }
    }

    @Test func staleSocketCleanupReplacesJunkFile() async throws {
        let socketURL = makeSocketURL()
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("junk".utf8).write(to: socketURL)

        let service = startService(at: socketURL)
        defer { service.stop() }

        let response = try await SolMacClient.send(
            IPCRequest(
                id: UUID(),
                protocolVersion: SolMacIPCConstants.currentProtocolVersion,
                command: .ping
            ),
            socketURL: socketURL
        )

        guard case .ok(.pong) = response.result else {
            Issue.record("Expected pong response")
            return
        }

        service.stop()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    }

    @Test func concurrentPingsDoNotBlockEachOther() async throws {
        let socketURL = makeSocketURL()
        let service = startService(at: socketURL)
        defer { service.stop() }

        try await withThrowingTaskGroup(of: IPCResponse.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await SolMacClient.send(
                        IPCRequest(
                            id: UUID(),
                            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
                            command: .ping
                        ),
                        socketURL: socketURL
                    )
                }
            }

            var count = 0
            for try await response in group {
                guard case .ok(.pong) = response.result else {
                    Issue.record("Expected pong response")
                    continue
                }
                count += 1
            }
            #expect(count == 5)
        }
    }

    @Test func statusRoundTripUsesResponderData() async throws {
        let socketURL = makeSocketURL()
        let service = startService(at: socketURL)
        defer { service.stop() }

        let response = try await SolMacClient.send(
            IPCRequest(
                id: UUID(),
                protocolVersion: SolMacIPCConstants.currentProtocolVersion,
                command: .status
            ),
            socketURL: socketURL
        )

        guard case .ok(.status(let status)) = response.result else {
            Issue.record("Expected status response")
            return
        }

        #expect(!status.isRecording)
        #expect(!status.isPaused)
        #expect(!status.serverConfigured)
        #expect(status.pendingUploadCount == 0)
        #expect(status.segmentTimeRemainingSeconds == nil)
    }

    private func startService(at socketURL: URL) -> SolMacIPCService {
        try? FileManager.default.removeItem(at: socketURL)
        let service = SolMacIPCService(
            responder: SolMacResponder(appState: AppState.forSnapshot()),
            socketURL: socketURL
        )
        service.start()
        waitForSocket(at: socketURL)
        return service
    }

    private func waitForSocket(at socketURL: URL) {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketURL.path) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func makeSocketURL() -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sol-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return directory.appendingPathComponent("sol-mac.sock")
    }
}
