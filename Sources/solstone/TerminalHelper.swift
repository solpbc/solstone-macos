// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os

/// What the bundled helper reports, one JSON object per line.
enum TerminalHelperEvent: Equatable, Sendable {
    case ready
    case segment
    case tmuxHealth(found: Bool)
    case stopped

    static func parse(_ line: Data) -> TerminalHelperEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        switch event {
        case "ready": return .ready
        case "segment": return .segment
        case "stopped": return .stopped
        case "health":
            switch object["tmux"] as? String {
            case "found": return .tmuxHealth(found: true)
            case "missing": return .tmuxHealth(found: false)
            default: return nil
            }
        default: return nil
        }
    }
}

/// Splits a byte stream into lines, keeping any unfinished tail.
struct TerminalLineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[pending.startIndex..<newline]))
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }
}

/// One run of the helper. Its stdin stays open for the life of the app, so if the
/// app dies the helper sees it close and shuts itself down.
final class TerminalHelperProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = TerminalLineBuffer()

    init(
        helper: URL,
        spool: URL,
        tmux: String,
        settings: URL?,
        environment: [String: String],
        onEvent: @escaping @Sendable (TerminalHelperEvent) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        process.executableURL = helper
        var arguments = ["run", "--spool", spool.path, "--tmux", tmux]
        if let settings { arguments += ["--settings", settings.path] }
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else {
                handle.readabilityHandler = nil
                return
            }
            let lines = self.lock.withLock { self.buffer.append(data) }
            for line in lines {
                if let event = TerminalHelperEvent.parse(line) { onEvent(event) }
            }
        }
        process.terminationHandler = { process in onExit(process.terminationStatus) }
    }

    func start() throws {
        // A write to a helper that has exited must come back as an error, not a signal.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
    }

    private func send(_ line: String) {
        // A helper that has already gone is not an error here.
        try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func sendSync(working: Bool) {
        send("{\"cmd\":\"sync\",\"state\":\"\(working ? "working" : "idle")\"}")
    }

    func sendStop() {
        send("{\"cmd\":\"stop\"}")
    }

    /// Past the bounded wait for a stop, nothing short of this ends a wedged helper.
    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}

/// Finds tmux by absolute path: an app started from the Dock has none of the
/// shell's `PATH`.
enum TerminalTmuxLocator {
    static let wellKnown = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"]

    static func locate(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        loginShellLookup: () -> String? = TerminalTmuxLocator.askLoginShell
    ) -> String? {
        if let found = wellKnown.first(where: isExecutable) { return found }
        guard let path = loginShellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), isExecutable(path) else { return nil }
        return path
    }

    /// The well-known link to the same tmux as `path`, when there is one. Homebrew's
    /// versioned Cellar path stops existing when tmux upgrades; its `bin` link doesn't.
    static func stableLink(
        to path: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    ) -> String {
        let target = resolve(path)
        return wellKnown.first { $0 != path && isExecutable($0) && resolve($0) == target } ?? path
    }

    static func askLoginShell() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v tmux"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // A shell profile that hangs must not keep terminal from starting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Runs the helper's `legacy` command and waits for what it lists.
enum TerminalLegacyRunner {
    static func run(helper: URL, root: URL) -> TerminalLegacyListing {
        let process = Process()
        let output = Pipe()
        process.executableURL = helper
        process.arguments = ["legacy", "--from", root.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failed(UICopy.Terminal.oldSpoolUnreadable) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return TerminalLegacyListing.parse(status: process.terminationStatus, output: data)
    }
}
