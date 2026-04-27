// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
@testable import sol_mac

@Suite("SolMacClientErrorMapping")
struct SolMacClientErrorMappingTests {
    @Test func nonListeningFileAtSocketPathMapsToAppNotRunning() async throws {
        let socketURL = makeSocketURL()
        defer { try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("junk".utf8).write(to: socketURL)

        await expectAppNotRunning(socketURL: socketURL, connectTimeout: .milliseconds(200))
    }

    @Test func missingSocketPathMapsToAppNotRunning() async throws {
        let socketURL = makeSocketURL()
        defer { try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent()) }

        await expectAppNotRunning(socketURL: socketURL, connectTimeout: .milliseconds(200))
    }

    private func expectAppNotRunning(socketURL: URL, connectTimeout: Duration) async {
        do {
            _ = try await SolMacClient.send(
                IPCRequest(
                    id: UUID(),
                    protocolVersion: SolMacIPCConstants.currentProtocolVersion,
                    command: .ping
                ),
                socketURL: socketURL,
                connectTimeout: connectTimeout
            )
            Issue.record("Expected SolMacClientError.appNotRunning")
        } catch let error as SolMacClientError {
            guard case .appNotRunning = error else {
                Issue.record("Expected SolMacClientError.appNotRunning, got \(String(describing: error))")
                return
            }
        } catch {
            Issue.record("Expected SolMacClientError.appNotRunning, got \(String(describing: error))")
        }
    }

    private func makeSocketURL() -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sol-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return directory.appendingPathComponent("sol-mac.sock")
    }
}
