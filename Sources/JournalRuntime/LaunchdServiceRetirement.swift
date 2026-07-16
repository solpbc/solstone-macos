// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import SolstoneCore

internal let legacyJournalLaunchdLabel = "org.solpbc.solstone"

internal enum LaunchdPlistState: Equatable, Sendable {
    case absent
    case malformed(String)
    case present(LaunchdPlist)
}

internal struct LaunchdPlist: Equatable, Sendable {
    let path: String
    let label: String
    let programArguments: [String]
    let standardOutPath: String
}

internal enum LaunchdRunState: Equatable, Sendable {
    case running
    case notRunning
}

internal enum LaunchdPrintState: Equatable, Sendable {
    case loaded(LaunchdLoadedJob)
    case notFound113
    case otherError(exitCode: Int32, output: String)
}

internal struct LaunchdLoadedJob: Equatable, Sendable {
    let path: String
    let state: LaunchdRunState
    let program: String
    let arguments: [String]
    let pid: pid_t?
}

internal enum LaunchdRootProof: Equatable, Sendable {
    case matches
    case differs
    case unclassifiable
}

internal enum LaunchdOwnershipDecision: Equatable, Sendable {
    case noOp
    case retire
    case block(String)
}

internal func legacyLaunchdPlistURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    homeDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("LaunchAgents", isDirectory: true)
        .appendingPathComponent("\(legacyJournalLaunchdLabel).plist")
}

internal func loadLaunchdPlist(
    at url: URL,
    fileManager: FileManager = .default,
    expectedLabel: String = legacyJournalLaunchdLabel
) -> LaunchdPlistState {
    guard fileManager.fileExists(atPath: url.path) else {
        return .absent
    }
    do {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let plist = object as? [String: Any],
              let label = plist["Label"] as? String,
              let arguments = plist["ProgramArguments"] as? [String],
              !arguments.isEmpty,
              let standardOutPath = plist["StandardOutPath"] as? String,
              label == expectedLabel else {
            return .malformed("missing required launchd keys")
        }
        return .present(LaunchdPlist(
            path: url.path,
            label: label,
            programArguments: arguments,
            standardOutPath: standardOutPath
        ))
    } catch {
        return .malformed(error.localizedDescription)
    }
}

internal func rootProof(for plistState: LaunchdPlistState, knownRoot: URL) -> LaunchdRootProof {
    guard case .present(let plist) = plistState else {
        return .unclassifiable
    }
    let expected = knownRoot
        .appendingPathComponent("health", isDirectory: true)
        .appendingPathComponent("service.log")
        .path
    let actualCanonical = SolOwnership.canonicalPath(plist.standardOutPath)
    let expectedCanonical = SolOwnership.canonicalPath(expected)
    return actualCanonical == expectedCanonical ? .matches : .differs
}

internal func parseLaunchdPrint(exitCode: Int32, output: String) -> LaunchdPrintState {
    if exitCode == 113 {
        return .notFound113
    }
    guard exitCode == 0 else {
        return .otherError(exitCode: exitCode, output: output)
    }

    var path = ""
    var state: LaunchdRunState?
    var program = ""
    var arguments: [String] = []
    var pid: pid_t?
    var inArguments = false

    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if inArguments {
            if line == "}" {
                inArguments = false
            } else if !line.isEmpty {
                arguments.append(line)
            }
            continue
        }
        if line == "arguments = {" {
            inArguments = true
        } else if line.hasPrefix("path = ") {
            path = String(line.dropFirst("path = ".count))
        } else if line == "state = running" {
            state = .running
        } else if line == "state = not running" {
            state = .notRunning
        } else if line.hasPrefix("program = ") {
            program = String(line.dropFirst("program = ".count))
        } else if line.hasPrefix("pid = ") {
            let value = line.dropFirst("pid = ".count)
            if let parsed = Int32(String(value), radix: 10) {
                pid = pid_t(parsed)
            }
        }
    }

    guard let state, !path.isEmpty, !program.isEmpty, !arguments.isEmpty else {
        return .otherError(exitCode: exitCode, output: "malformed launchctl print")
    }
    return .loaded(LaunchdLoadedJob(
        path: path,
        state: state,
        program: program,
        arguments: arguments,
        pid: pid
    ))
}

internal func launchdPrintAgreesWithPlist(_ job: LaunchdLoadedJob, plist: LaunchdPlist) -> Bool {
    job.program == plist.programArguments.first
        && job.arguments == plist.programArguments
        && SolOwnership.canonicalPath(job.path) == SolOwnership.canonicalPath(plist.path)
}

internal func decideLaunchdOwnership(
    plistState: LaunchdPlistState,
    printState: LaunchdPrintState,
    rootProof: LaunchdRootProof
) -> LaunchdOwnershipDecision {
    switch (plistState, printState, rootProof) {
    case (.absent, .loaded, .matches):
        return .block("launchd proof impossible without plist")
    case (.absent, .loaded, .differs):
        return .block("launchd plist absent while label is loaded")
    case (.absent, .loaded, .unclassifiable):
        return .block("launchd plist absent while label is loaded")
    case (.absent, .notFound113, .matches):
        return .block("launchd proof impossible without plist")
    case (.absent, .notFound113, .differs):
        return .block("launchd proof impossible without plist")
    case (.absent, .notFound113, .unclassifiable):
        return .noOp
    case (.absent, .otherError, .matches):
        return .block("launchctl proof impossible without plist")
    case (.absent, .otherError, .differs):
        return .block("launchctl proof failed")
    case (.absent, .otherError, .unclassifiable):
        return .block("launchctl proof failed")

    case (.malformed, .loaded, .matches):
        return .block("launchd plist malformed")
    case (.malformed, .loaded, .differs):
        return .block("launchd plist malformed")
    case (.malformed, .loaded, .unclassifiable):
        return .block("launchd plist malformed")
    case (.malformed, .notFound113, .matches):
        return .block("launchd plist malformed")
    case (.malformed, .notFound113, .differs):
        return .block("launchd plist malformed")
    case (.malformed, .notFound113, .unclassifiable):
        return .block("launchd plist malformed")
    case (.malformed, .otherError, .matches):
        return .block("launchd plist malformed")
    case (.malformed, .otherError, .differs):
        return .block("launchd plist malformed")
    case (.malformed, .otherError, .unclassifiable):
        return .block("launchd plist malformed")

    case (.present(let plist), .loaded(let job), .matches):
        return launchdPrintAgreesWithPlist(job, plist: plist)
            ? .retire
            : .block("launchctl job does not match plist")
    case (.present, .loaded, .differs):
        return .block("launchd plist points at a different journal")
    case (.present, .loaded, .unclassifiable):
        return .block("launchd plist root could not be verified")
    case (.present, .notFound113, .matches):
        return .retire
    case (.present, .notFound113, .differs):
        return .block("launchd plist points at a different journal")
    case (.present, .notFound113, .unclassifiable):
        return .block("launchd plist root could not be verified")
    case (.present, .otherError, .matches):
        return .block("launchctl proof failed")
    case (.present, .otherError, .differs):
        return .block("launchd plist points at a different journal")
    case (.present, .otherError, .unclassifiable):
        return .block("launchctl proof failed")
    }
}

internal func runLaunchctlPrint(
    label: String = legacyJournalLaunchdLabel,
    uid: uid_t = getuid(),
    runner: SubprocessRunning
) async -> LaunchdPrintState {
    let output = LockedLaunchdOutput()
    do {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(uid)/\(label)"],
            environment: nil,
            stdoutHandler: { data in output.append(data) },
            stderrHandler: { data in output.append(data) }
        )
        return parseLaunchdPrint(exitCode: result.exitCode, output: output.string)
    } catch {
        return .otherError(exitCode: -1, output: error.localizedDescription)
    }
}

internal func runLaunchctlBootout(
    label: String = legacyJournalLaunchdLabel,
    uid: uid_t = getuid(),
    runner: SubprocessRunning
) async -> SubprocessResult? {
    do {
        return try await runner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootout", "gui/\(uid)/\(label)"],
            environment: nil,
            stdoutHandler: { _ in },
            stderrHandler: { _ in }
        )
    } catch {
        return nil
    }
}

internal func waitForLaunchdAbsence(
    label: String = legacyJournalLaunchdLabel,
    uid: uid_t = getuid(),
    runner: SubprocessRunning,
    clock: any MonotonicClock,
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(100)
) async -> Bool {
    // Defensive: prep measured immediate disappearance, but launchd state under
    // load is cheap to poll and the child can outlive bootout briefly.
    let deadline = clock.now() + timeout
    while clock.now() < deadline {
        if await runLaunchctlPrint(label: label, uid: uid, runner: runner) == .notFound113 {
            return true
        }
        await clock.sleep(for: pollInterval)
    }
    return await runLaunchctlPrint(label: label, uid: uid, runner: runner) == .notFound113
}

private final class LockedLaunchdOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var string: String {
        lock.withLock { String(data: data, encoding: .utf8) ?? "" }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }
}
