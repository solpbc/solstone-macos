// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

/// Where the old app keeps things on this Mac, and how to talk to launchd.
struct TerminalTakeoverHost: Sendable {
    var root: URL
    var plistURL: URL
    var launchctl: @Sendable ([String]) -> Bool
    var uid: UInt32

    static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> TerminalTakeoverHost {
        TerminalTakeoverHost(
            root: home.appendingPathComponent("Library/Application Support/solstone-tmux", isDirectory: true),
            plistURL: home.appendingPathComponent("Library/LaunchAgents/com.solstone.tmux.plist"),
            launchctl: { arguments in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            },
            uid: getuid()
        )
    }

    var serviceTarget: String { "gui/\(uid)/com.solstone.tmux" }
    var capturesURL: URL { root.appendingPathComponent("captures", isDirectory: true) }
    var credentialsURL: URL { root.appendingPathComponent("credentials.json") }
    var configURL: URL { root.appendingPathComponent("config.json") }
    var localObserverURL: URL { root.appendingPathComponent("local-observer.json") }
}

enum TerminalStepError: Error, Equatable {
    /// Safe to retry: the old service would not stop.
    case temporary(String)
    /// Nothing changed, and retrying alone won't help.
    case refused(String)
}

enum TerminalTakeoverSteps {
    static let label = "com.solstone.tmux"
    private static let carriedKeys = [
        "capture_interval", "segment_interval", "output_sessions", "status_indicator",
        "pane_title", "working_directory", "executable",
    ]

    /// Read-only: it never opens the old app's lock or touches its spool.
    static func isInstalled(_ host: TerminalTakeoverHost) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: host.plistURL.path) || manager.fileExists(atPath: host.credentialsURL.path) {
            return true
        }
        if let entries = try? manager.contentsOfDirectory(atPath: host.capturesURL.path), !entries.isEmpty {
            return true
        }
        return host.launchctl(["print", host.serviceTarget])
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func plistIsOurs(_ plist: [String: Any]) -> Bool {
        guard plist["Label"] as? String == label else { return false }
        let program = (plist["ProgramArguments"] as? [String])?.first ?? plist["Program"] as? String
        return (program as NSString?)?.lastPathComponent == "solstone-tmux"
    }

    /// What must be read before anything changes.
    static func prepare(_ host: TerminalTakeoverHost) throws -> TerminalTakeoverRecord {
        var record = TerminalTakeoverRecord()
        if FileManager.default.fileExists(atPath: host.plistURL.path) {
            guard let plist = readPlist(host.plistURL), plistIsOurs(plist) else {
                throw TerminalStepError.refused(UICopy.Terminal.plistNotOurs)
            }
            let environment = plist["EnvironmentVariables"] as? [String: String]
            record.tmuxTmpdir = environment?["TMUX_TMPDIR"]
        }
        if let data = try? Data(contentsOf: host.localObserverURL),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            record.tmuxPath = object["tmux_path"] as? String
        }
        record.carriedSettings = carriedSettings(host)
        return record
    }

    /// The old capture choices the helper would accept, key by key. A value it
    /// would refuse would stop the helper starting at all, so it's left out.
    static func carriedSettings(_ host: TerminalTakeoverHost) -> Data? {
        guard let data = try? Data(contentsOf: host.configURL),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var carried: [String: Any] = [:]
        for key in carriedKeys {
            guard let value = saved[key], isAcceptable(key: key, value: value) else { continue }
            carried[key] = value
        }
        guard !carried.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: carried, options: [.sortedKeys])
    }

    private static func isAcceptable(key: String, value: Any) -> Bool {
        switch key {
        case "capture_interval", "segment_interval":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let double = number.doubleValue
            return double == double.rounded() && double >= 1
        case "output_sessions":
            guard let sessions = value as? [String] else { return false }
            return sessions.allSatisfy { !$0.isEmpty }
        case "status_indicator", "pane_title", "working_directory", "executable":
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        default:
            return false
        }
    }

    /// The old service stops and never comes back. Validated before anything
    /// is touched, so a plist that isn't ours sees no `bootout`.
    static func stopForGood(_ host: TerminalTakeoverHost) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: host.plistURL.path) {
            guard let plist = readPlist(host.plistURL), plistIsOurs(plist) else {
                throw TerminalStepError.refused(UICopy.Terminal.plistNotOurs)
            }
        }
        _ = host.launchctl(["bootout", host.serviceTarget])
        _ = host.launchctl(["disable", host.serviceTarget])
        guard !host.launchctl(["print", host.serviceTarget]) else {
            throw TerminalStepError.temporary(UICopy.Terminal.oldAppStillRunning)
        }
        for url in [host.plistURL, host.localObserverURL] {
            do {
                try manager.removeItem(at: url)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileNoSuchFileError {
                continue
            } catch {
                throw TerminalStepError.temporary(error.localizedDescription)
            }
        }
    }

    /// Reads the old pairing. `nil` when absent or unreadable.
    static func readLegacyCredential(_ host: TerminalTakeoverHost) -> TerminalLegacyCredential? {
        guard let data = try? Data(contentsOf: host.credentialsURL) else { return nil }
        return try? JSONDecoder().decode(TerminalLegacyCredential.self, from: data)
    }

    /// Removes the old credential once the journal has stopped accepting it.
    static func tidyCredential(_ host: TerminalTakeoverHost, continuity: TerminalContinuity?) {
        guard continuity == .continued else { return }
        try? FileManager.default.removeItem(at: host.credentialsURL)
    }
}

/// What the helper's `legacy` command reported.
enum TerminalLegacyListing: Equatable, Sendable {
    case listed(segments: [TerminalSpoolSegment], held: Int, problems: [String])
    /// The old process still holds its lock.
    case locked
    /// No complete listing: the helper exited without `done`.
    case failed(String)

    /// Parses the helper's output. Only a `done` line makes a listing complete.
    static func parse(status: Int32, output: Data) -> TerminalLegacyListing {
        if status == 75 { return .locked }
        var segments: [TerminalSpoolSegment] = []
        var held = 0
        var problems: [String] = []
        var done = false
        for line in output.split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let event = object["event"] as? String else { continue }
            switch event {
            case "segment":
                guard let day = object["day"] as? String,
                      let name = object["segment"] as? String,
                      let path = object["dir"] as? String,
                      let files = object["files"] as? [String] else { continue }
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                segments.append(TerminalSpoolSegment(
                    day: day,
                    segment: name,
                    directory: directory,
                    files: files.map { directory.appendingPathComponent($0) },
                    zone: zone(from: object["zone"] as? [String: Any])
                ))
            case "held":
                held += 1
            case "problem":
                if let path = object["path"] as? String { problems.append(path) }
            case "done":
                done = true
            default:
                break
            }
        }
        guard status == 0, done else { return .failed(UICopy.Terminal.oldSpoolUnreadable) }
        return .listed(segments: segments, held: held, problems: problems)
    }

    private static func zone(from object: [String: Any]?) -> [String: IngestJSONValue]? {
        guard let object, let offset = (object["utc_offset_seconds"] as? NSNumber)?.intValue else { return nil }
        var meta: [String: IngestJSONValue] = ["utc_offset_seconds": .integer(offset)]
        if let tz = object["tz"] as? String { meta["tz"] = .string(tz) }
        return meta
    }
}
