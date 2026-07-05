import Foundation
import JournalRuntime

public final class MockRuntimeMaterializer: RuntimeMaterializing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<MaterializedRuntime, Error>
    private var calls = 0

    public var materializeCalls: Int { lock.withLock { calls } }

    public init(result: Result<MaterializedRuntime, Error>) {
        self.result = result
    }

    public func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime {
        lock.withLock { calls += 1 }
        return try result.get()
    }
}

public final class MockSupervisedChildRunner: SupervisedChildRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: Error?
    private var starts = 0
    private var readyMarks = 0
    private var stops = 0
    private var restarts = 0
    private var runtimeKey: String?
    private var journalRoot: URL?
    private var terminalDiagnostic: JournalDiagnostic?

    public var startCalls: Int { lock.withLock { starts } }
    public var markReadyCalls: Int { lock.withLock { readyMarks } }
    public var stopCalls: Int { lock.withLock { stops } }
    public var restartCalls: Int { lock.withLock { restarts } }
    public var runningJournalRoot: URL? { lock.withLock { journalRoot } }

    public init(startError: Error? = nil, terminalDiagnostic: JournalDiagnostic? = nil) {
        self.startError = startError
        self.terminalDiagnostic = terminalDiagnostic
    }

    public func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws {
        lock.withLock { starts += 1 }
        if let startError {
            throw startError
        }
        lock.withLock {
            runtimeKey = runtime.key
            self.journalRoot = journalRoot.standardizedFileURL
            terminalDiagnostic = nil
        }
    }

    public func restart() async throws {
        lock.withLock {
            restarts += 1
            terminalDiagnostic = nil
        }
    }

    public func stop() async {
        lock.withLock {
            stops += 1
            runtimeKey = nil
            journalRoot = nil
            terminalDiagnostic = nil
        }
    }

    public func stopForTermination() async {
        lock.withLock {
            runtimeKey = nil
            journalRoot = nil
        }
    }

    public func currentRuntimeKey() async -> String? {
        lock.withLock { runtimeKey }
    }

    public func terminalReason() async -> JournalDiagnostic? {
        lock.withLock { terminalDiagnostic }
    }

    public func setTerminalDiagnostic(_ diagnostic: JournalDiagnostic?) {
        lock.withLock { terminalDiagnostic = diagnostic }
    }

    public func markReady() async {
        lock.withLock { readyMarks += 1 }
    }
}

public final class MockSingleSupervisorGate: SingleSupervisorGating, @unchecked Sendable {
    private let lock = NSLock()
    private let result: SingleSupervisorGateResult
    private var calls = 0

    public var prepareCalls: Int { lock.withLock { calls } }

    public init(result: SingleSupervisorGateResult = .success) {
        self.result = result
    }

    public func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        lock.withLock { calls += 1 }
        return result
    }
}

public struct MockJournalReadinessGate: JournalReadinessChecking {
    public var result: JournalReadinessResult
    public var beforeReturn: (@Sendable () async -> Void)?

    public init(result: JournalReadinessResult, beforeReturn: (@Sendable () async -> Void)? = nil) {
        self.result = result
        self.beforeReturn = beforeReturn
    }

    public func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        timeout: Duration,
        terminalCheck: @escaping @Sendable () async -> JournalDiagnostic?
    ) async -> JournalReadinessResult {
        await beforeReturn?()
        return result
    }
}

public func makeRuntime() throws -> MaterializedRuntime {
    let root = try makeTemporaryDirectory()
    let layout = SolstoneRuntimeLayout(rootURL: root)
    try FileManager.default.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: layout.journalBinary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.journalBinary.path)
    return MaterializedRuntime(key: "test-key", layout: layout)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-owned-journal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
