// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import JournalRuntime

/// Shared helpers for the opt-in native runtime integration tier. See
/// `NativeRuntimeFixture` for the isolation contract and `make integration-native` for the
/// entry point.
enum NativeIntegration {
    /// Exit code the native `install-models --required-only --check` uses for a missing,
    /// invalid or mismatched RF-DETR sidecar (`sysexits` `EX_DATAERR`).
    static let requiredModelsCheckDataError: Int32 = 65

    /// Relative path of the RF-DETR install sidecar under a journal root.
    static let rfdetrSidecarRelativePath = "cache/providers/rfdetr/.rfdetr-install.json"

    static let requiredModelsCheckArguments = ["install-models", "--required-only", "--check"]

    /// Run the app's exact native setup argv (the same builder production uses) against the
    /// fixture's journal root, honouring the fixture's isolated home. Setup runs from the home,
    /// not from inside the journal: native `setup` refuses a `--journal` equal to its working
    /// directory (it reports "--journal must not be empty"), and the app's own setup runner
    /// never sets a working directory either.
    static func runAppSetup(_ fixture: NativeRuntimeFixture) async throws -> NativeCommandResult {
        try await fixture.run(
            JournalSetupCommand.setupArguments(journalURL: fixture.journalRoot, skipService: true),
            timeout: .seconds(180),
            currentDirectory: fixture.home
        )
    }

    /// The native check the app's reconciler is expected to satisfy.
    static func requiredModelsCheck(_ fixture: NativeRuntimeFixture) async throws -> NativeCommandResult {
        try await fixture.run(requiredModelsCheckArguments, timeout: .seconds(60))
    }

    static func sidecarURL(_ fixture: NativeRuntimeFixture) -> URL {
        fixture.journalRoot.appendingPathComponent(rfdetrSidecarRelativePath)
    }

    /// Rewrite the sidecar's recorded engine digest so the cache reads as a previous runtime's:
    /// the state a Journal upgrade leaves behind.
    static func staleSidecar(_ fixture: NativeRuntimeFixture) throws {
        let url = sidecarURL(fixture)
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeIntegrationError.sidecarUnreadable(url.path)
        }
        object["engine_sha256"] = String(repeating: "0", count: 64)
        let rewritten = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try rewritten.write(to: url, options: .atomic)
    }

    /// Write the paired-device door port both sides read from `config/journal.json`
    /// (`pairing.direct_port`), preserving every other key native setup wrote.
    static func configureDirectDoorPort(_ fixture: NativeRuntimeFixture, port: Int) throws {
        let url = fixture.journalRoot
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("journal.json")
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        var pairing = object["pairing"] as? [String: Any] ?? [:]
        pairing["direct_port"] = port
        object["pairing"] = pairing
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// A receipt context that records nothing: no app identity means no payload receipts are
    /// drafted, which keeps this tier from inventing an app bundle it does not have.
    static func silentReceiptContext() -> JournalRuntimeEntryReceiptContext {
        JournalRuntimeEntryReceiptContext(
            attemptID: JournalRuntimeEntryAttemptID(),
            sink: InMemoryJournalRuntimeEntryReceiptSink(),
            appIdentity: nil,
            candidateProvenance: nil
        )
    }

    static func processExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Poll until `condition` holds or the deadline passes. Returns whether it held.
    static func waitUntil(
        timeout: Duration,
        pollEvery interval: Duration = .milliseconds(50),
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return await condition()
    }

    /// Best-effort teardown for processes a test admitted and then lost track of. Signals
    /// only the exact pids it is given, never a group or a name.
    static func killSurvivors(_ pids: [pid_t]) {
        for pid in pids where processExists(pid) {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}

enum NativeIntegrationError: Error, CustomStringConvertible {
    case sidecarUnreadable(String)

    var description: String {
        switch self {
        case .sidecarUnreadable(let path):
            return "rf-detr sidecar at \(path) is not a JSON object"
        }
    }
}

final class RuntimeStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [JournalRuntimeStatus] = []

    func append(_ status: JournalRuntimeStatus) {
        lock.withLock { statuses.append(status) }
    }

    func snapshot() -> [JournalRuntimeStatus] {
        lock.withLock { statuses }
    }
}
