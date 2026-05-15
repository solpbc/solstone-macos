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

    static func version(solPath: String, runner: SubprocessRunning = SubprocessRunner()) async -> String? {
        let stdoutAccumulator = SolVersionStdoutAccumulator()
        do {
            let result = try await withTimeout(seconds: 5.0) {
                try await runner.run(
                    executable: URL(fileURLWithPath: solPath),
                    arguments: ["--version"],
                    environment: nil,
                    stdoutHandler: { data in
                        append(data, to: stdoutAccumulator)
                    },
                    stderrHandler: { _ in }
                )
            }
            guard result.exitCode == 0 else { return nil }
            let stdoutString = await stdoutAccumulator.string
            return SolVersionParser.parse(stdoutString)
        } catch {
            return nil
        }
    }

    private static func append(_ data: Data, to accumulator: SolVersionStdoutAccumulator) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await accumulator.append(data)
            semaphore.signal()
        }
        semaphore.wait()
    }
}

private actor SolVersionStdoutAccumulator {
    private var data = Data()

    var string: String {
        String(data: data, encoding: .utf8) ?? ""
    }

    func append(_ chunk: Data) {
        data.append(chunk)
    }
}
