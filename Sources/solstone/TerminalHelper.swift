// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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
        onEvent: @escaping @Sendable (TerminalHelperEvent) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        process.executableURL = helper
        process.arguments = ["run", "--spool", spool.path, "--tmux", tmux]
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

    func kill() {
        if process.isRunning { process.terminate() }
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

    static func askLoginShell() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v tmux"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

/// Whether the separate solstone for tmux app is still on this Mac.
enum TerminalLegacyInstall {
    static func isPresent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/com.solstone.tmux.plist").path) {
            return true
        }
        let captures = home.appendingPathComponent("Library/Application Support/solstone-tmux/captures")
        if let entries = try? manager.contentsOfDirectory(atPath: captures.path), !entries.isEmpty {
            return true
        }
        return launchAgentIsLoaded()
    }

    private static func launchAgentIsLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/com.solstone.tmux"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
