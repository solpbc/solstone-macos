// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal enum SolBinaryLocator {
    static func findSolBinary(runner: SubprocessRunning = SubprocessRunner()) async -> String? {
        let preferred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/sol").path
        if FileManager.default.fileExists(atPath: preferred) {
            return preferred
        }

        let output = SolBinaryLocatorOutput()
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/which"),
                arguments: ["sol"],
                environment: nil,
                stdoutHandler: { data in
                    append(data, to: output)
                },
                stderrHandler: { _ in }
            )
            guard result.exitCode == 0 else {
                return nil
            }

            let path = await output.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func append(_ data: Data, to output: SolBinaryLocatorOutput) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await output.append(data)
            semaphore.signal()
        }
        semaphore.wait()
    }
}

private actor SolBinaryLocatorOutput {
    private var data = Data()

    var string: String {
        String(data: data, encoding: .utf8) ?? ""
    }

    func append(_ chunk: Data) {
        data.append(chunk)
    }
}
