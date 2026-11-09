// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

@main
enum SolstoneEntryPoint {
    static func main() {
        // This process's preflight stays false for its lifetime after the owner grants access and chooses Later, so the check runs in a new process.
        if let code = screenCaptureProbeExitCode(arguments: CommandLine.arguments, preflight: {
            // CGMainDisplayID() connects the window server before preflight.
            _ = CGMainDisplayID()
            return CGPreflightScreenCaptureAccess()
        }) {
            exit(code)
        }
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        if let exitCode = BrowserHostCommand.run(arguments: CommandLine.arguments) {
            exit(Int32(exitCode))
        }
#endif
        if case .usage(let exitCode) = AppCommandLine.decision(arguments: CommandLine.arguments) {
            print(UICopy.COMMAND_LINE_USAGE)
            exit(exitCode)
        }
        if case .heldElsewhere = AppInstanceLock.acquire() {
            print(UICopy.COMMAND_LINE_ALREADY_RUNNING)
            exit(0)
        }
        SolstoneCaptureApp.main()
    }
}
