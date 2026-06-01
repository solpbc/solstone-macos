import Foundation
import Testing
import SolstoneCore
@testable import solstone
@testable import sol_mac

@Suite("SolMacStatusIntegration")
@MainActor
struct SolMacStatusIntegrationTests {
    @Test func statusRoundTripFormatsExpectedFields() async throws {
        let socketURL = makeSocketURL()
        let appState = AppState.forSnapshot()
        appState.audioReconciledCount = 2
        let service = startService(at: socketURL, appState: appState)
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

        let formatted = formatStatus(status)
        #expect(formatted.contains("isRecording=false"))
        #expect(formatted.contains("serverConfigured=false"))
        #expect(formatted.contains("pendingUploadCount=0"))
        #expect(formatted.contains("segmentTimeRemainingSeconds=<unset>"))
        #expect(formatted.contains("audioReconciledCount=2"))
        #expect(status.audioReconciledCount == 2)
    }

    private func startService(at socketURL: URL, appState: AppState = AppState.forSnapshot()) -> SolMacIPCService {
        try? FileManager.default.removeItem(at: socketURL)
        let service = SolMacIPCService(
            responder: SolMacResponder(appState: appState),
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
