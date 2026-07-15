// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct PlacementReopenCommand: Sendable, Equatable {
    let predecessorPID: Int32
    let targetBundlePath: String
    let shellCommand: String
}

enum PlacementReopenLauncher {
    static let terminationBound: Duration = .seconds(30)
    static let pollInterval: Duration = .milliseconds(200)
    static let maxPolls = pollCount(bound: terminationBound, interval: pollInterval)

    static func command(predecessorPID: Int32, targetBundlePath: String) -> PlacementReopenCommand {
        let quotedTargetPath = singleQuotedShellArgument(targetBundlePath)
        let command = "i=0; while [ $i -lt \(maxPolls) ] && kill -0 \(predecessorPID) 2>/dev/null; do i=$((i+1)); sleep \(shellSeconds(pollInterval)); done; if ! kill -0 \(predecessorPID) 2>/dev/null; then /usr/bin/open \(quotedTargetPath); else exit 75; fi"
        return PlacementReopenCommand(
            predecessorPID: predecessorPID,
            targetBundlePath: targetBundlePath,
            shellCommand: command
        )
    }

    static func runDetached(_ command: PlacementReopenCommand, shellPath: String = "/bin/sh") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", command.shellCommand]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func waitForPredecessorExitThenLaunch(
        maxPolls: Int,
        pollInterval: Duration,
        isPredecessorAlive: @Sendable () async -> Bool,
        sleep: @Sendable (Duration) async -> Void,
        launch: @Sendable () -> Void
    ) async -> Bool {
        for _ in 0..<maxPolls {
            if await !isPredecessorAlive() {
                launch()
                return true
            }
            await sleep(pollInterval)
        }

        if await !isPredecessorAlive() {
            launch()
            return true
        }
        return false
    }

    private static func pollCount(bound: Duration, interval: Duration) -> Int {
        let boundMilliseconds = milliseconds(bound)
        let intervalMilliseconds = milliseconds(interval)
        guard intervalMilliseconds > 0 else { return 0 }
        return Int((boundMilliseconds + intervalMilliseconds - 1) / intervalMilliseconds)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }

    private static func shellSeconds(_ duration: Duration) -> String {
        let durationMilliseconds = milliseconds(duration)
        if durationMilliseconds % 1_000 == 0 {
            return String(durationMilliseconds / 1_000)
        }
        let seconds = durationMilliseconds / 1_000
        let milliseconds = durationMilliseconds % 1_000
        return "\(seconds).\(String(format: "%03d", Int(milliseconds)))"
    }

    private static func singleQuotedShellArgument(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
