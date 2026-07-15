// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

struct SolstoneProcessResult: Equatable {
    let terminationStatus: Int32
    let combinedOutput: String

    func throwIfFailed(_ operation: String) throws {
        guard terminationStatus == 0 else {
            throw SolstoneProcessError.failed(operation: operation, output: combinedOutput)
        }
    }
}

enum SolstoneProcessError: Error, Equatable {
    case failed(operation: String, output: String)
}

enum SolstoneProcessRunner {
    static func run(executable: String, arguments: [String]) throws -> SolstoneProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return SolstoneProcessResult(
            terminationStatus: process.terminationStatus,
            combinedOutput: output
        )
    }
}

enum SolstoneTrustVerificationError: Error, Equatable {
    case verifyFailed(String)
    case detailsFailed(String)
    case bundleIdentifierMismatch
    case teamIdentifierMismatch
    case processFailed(String)
}

struct SolstoneTrustVerifier {
    var runProcess: (String, [String]) throws -> SolstoneProcessResult

    init(runProcess: @escaping (String, [String]) throws -> SolstoneProcessResult = SolstoneProcessRunner.run) {
        self.runProcess = runProcess
    }

    func verifySolstoneApp(at url: URL) throws {
        do {
            let verify = try runProcess(
                "/usr/bin/codesign",
                ["--verify", "--strict", "--deep", "--verbose=2", url.path]
            )
            guard verify.terminationStatus == 0 else {
                throw SolstoneTrustVerificationError.verifyFailed(verify.combinedOutput)
            }

            let details = try runProcess(
                "/usr/bin/codesign",
                ["-dvvv", url.path]
            )
            guard details.terminationStatus == 0 else {
                throw SolstoneTrustVerificationError.detailsFailed(details.combinedOutput)
            }
            guard details.combinedOutput.contains("Identifier=\(SolstoneIdentity.bundleIdentifier)") else {
                throw SolstoneTrustVerificationError.bundleIdentifierMismatch
            }
            guard details.combinedOutput.contains("TeamIdentifier=\(SolstoneIdentity.teamIdentifier)") else {
                throw SolstoneTrustVerificationError.teamIdentifierMismatch
            }
        } catch let error as SolstoneTrustVerificationError {
            throw error
        } catch {
            throw SolstoneTrustVerificationError.processFailed(String(describing: error))
        }
    }
}
