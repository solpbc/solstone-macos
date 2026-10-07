// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import ServiceManagement

private let journalWatchdogLabel = "app.solstone.journal.watchdog"

/// `Contents/MacOS/journal` is the app. The forwarded command is the bundled
/// `Contents/Resources/solstone-runtime/bin/solstone` with `journal` prepended to the tail.
/// Run with command-line arguments, this executable hands them to that command before any
/// AppKit or SwiftUI startup, so `journal --version` answers and exits instead of starting the app's run loop.
enum JournalCommandLine {
    enum Route: Equatable {
        case app
        case commandLine
    }

    enum Action {
        case app
        case exec(arguments: [String])
        case execAfterWatchdogUnregister(arguments: [String])
        case stop(exitCode: Int32, message: String)
    }

    /// A Finder, Dock, login-item or watchdog launch passes no arguments. Xcode and
    /// `open --args` can pass Cocoa's own `-psn_…` and `-<Default> <value>` arguments,
    /// which stay with the app. A subcommand, a `--` flag, `-h` or `-V` is a command line.
    static func route(arguments: [String]) -> Route {
        guard let first = arguments.dropFirst().first else { return .app }
        if first == "-h" || first == "-V" || first.hasPrefix("--") || !first.hasPrefix("-") {
            return .commandLine
        }
        return .app
    }

    @MainActor
    static func dispatch(arguments: [String], loginItems: any LoginItemManaging) -> Action {
        guard route(arguments: arguments) == .commandLine else { return .app }
        guard Array(arguments.dropFirst()) == ["setup", "--clean-uninstall", "--yes"] else {
            return .exec(arguments: arguments)
        }

        do {
            // Unregistering the agent does not quit a running Journal.app.
            try loginItems.unregister()
        } catch {
            let serviceError = error as NSError
            guard serviceError.domain == SMAppServiceErrorDomain,
                  serviceError.code == Int(kSMErrorJobNotFound) else {
                return .stop(
                    exitCode: 78,
                    message: "journal: could not unregister \(journalWatchdogLabel): \(error.localizedDescription). setup cleanup was not started.\n"
                )
            }
        }

        return .execAfterWatchdogUnregister(arguments: arguments)
    }

    static func commandLineURL(executableURL: URL) -> URL {
        executableURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/solstone-runtime/bin/solstone")
    }

    static func execArgv(executableURL: URL, arguments: [String]) -> [String] {
        [commandLineURL(executableURL: executableURL).path, "journal"] + Array(arguments.dropFirst())
    }

    static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    /// Replaces this process with the bundled command line, or exits 78 saying why it could not.
    static func exec(arguments: [String]) -> Never {
        guard let executableURL = currentExecutableURL() else {
            fail("journal: could not locate the journal app's own executable.\n")
        }
        let argv = execArgv(executableURL: executableURL, arguments: arguments)
        let path = argv[0]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        execv(path, cArgv)
        let reason = String(cString: strerror(errno))
        fail("journal: could not run the journal command line at \(path): \(reason); reinstall the journal app.\n")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(message.utf8))
        exit(78)
    }
}

@main
enum JournalEntryPoint {
    @MainActor
    static func main() {
        switch JournalCommandLine.dispatch(
            arguments: CommandLine.arguments,
            loginItems: LiveJournalLoginItemManager()
        ) {
        case .app:
            JournalApp.main()
        case .exec(let arguments):
            JournalCommandLine.exec(arguments: arguments)
        case .execAfterWatchdogUnregister(let arguments):
            // execv replaces this process, so the notice has to precede exec.
            FileHandle.standardError.write(Data(
                "journal: \(journalWatchdogLabel) registration is already gone.\n".utf8
            ))
            JournalCommandLine.exec(arguments: arguments)
        case .stop(let exitCode, let message):
            FileHandle.standardError.write(Data(message.utf8))
            exit(exitCode)
        }
    }
}
