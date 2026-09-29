// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@main
enum SolstoneEntryPoint {
    static func main() {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        if let exitCode = BrowserHostCommand.run(arguments: CommandLine.arguments) {
            exit(Int32(exitCode))
        }
#endif
        SolstoneCaptureApp.main()
    }
}
