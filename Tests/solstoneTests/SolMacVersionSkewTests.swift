import ArgumentParser
import Foundation
import Testing
import SolstoneCore
@testable import sol_mac

@Suite("SolMacVersionSkew")
struct SolMacVersionSkewTests {
    @Test func responseWithMismatchedServerProtocolExits() {
        let response = IPCResponse(
            id: UUID(),
            serverProtocolVersion: 2,
            capabilities: nil,
            result: .ok(.empty)
        )

        #expect(throws: ExitCode.self) {
            try validateResponseProtocol(response)
        }
    }
}
