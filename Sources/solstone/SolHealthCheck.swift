import Foundation
import os

enum SolHealthCheck {
    static func run(solPath: String, runner: SubprocessRunning = SubprocessRunner()) async -> Bool {
        do {
            let result = try await withTimeout(seconds: 5.0) {
                try await runner.run(
                    executable: URL(fileURLWithPath: solPath),
                    arguments: ["health"],
                    environment: nil,
                    stdoutHandler: { _ in },
                    stderrHandler: { _ in }
                )
            }
            if result.exitCode == 0 {
                Logger.setup.info("sol health: ok")
                return true
            }
            Logger.setup.info("sol health: unhealthy(exitCode=\(result.exitCode, privacy: .public))")
            return false
        } catch is TimeoutError {
            Logger.setup.info("sol health: unhealthy(timeout)")
            return false
        } catch {
            Logger.setup.info("sol health: unhealthy(error=\(String(describing: error), privacy: .public))")
            return false
        }
    }
}
