import Foundation
@testable import solstone

final class MockRuntimeMaterializer: RuntimeMaterializing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<MaterializedRuntime, Error>
    private var calls = 0

    var materializeCalls: Int { lock.withLock { calls } }

    init(result: Result<MaterializedRuntime, Error>) {
        self.result = result
    }

    func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime {
        lock.withLock { calls += 1 }
        return try result.get()
    }
}

final class MockSupervisedChildRunner: SupervisedChildRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: Error?
    private var starts = 0
    private var readyMarks = 0
    private var stops = 0
    private var restarts = 0
    private var runtimeKey: String?
    private var journalRoot: URL?

    var startCalls: Int { lock.withLock { starts } }
    var markReadyCalls: Int { lock.withLock { readyMarks } }
    var stopCalls: Int { lock.withLock { stops } }
    var restartCalls: Int { lock.withLock { restarts } }
    var runningJournalRoot: URL? { lock.withLock { journalRoot } }

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws {
        lock.withLock { starts += 1 }
        if let startError {
            throw startError
        }
        lock.withLock {
            runtimeKey = runtime.key
            self.journalRoot = journalRoot.standardizedFileURL
        }
    }

    func restart() async throws {
        lock.withLock { restarts += 1 }
    }

    func stop() async {
        lock.withLock {
            stops += 1
            runtimeKey = nil
            journalRoot = nil
        }
    }

    func stopForTermination() async {
        lock.withLock {
            runtimeKey = nil
            journalRoot = nil
        }
    }

    func currentRuntimeKey() async -> String? {
        lock.withLock { runtimeKey }
    }

    func markReady() async {
        lock.withLock { readyMarks += 1 }
    }
}

final class MockSingleSupervisorGate: SingleSupervisorGating, @unchecked Sendable {
    private let lock = NSLock()
    private let result: SingleSupervisorGateResult
    private var calls = 0

    var prepareCalls: Int { lock.withLock { calls } }

    init(result: SingleSupervisorGateResult = .success) {
        self.result = result
    }

    func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        lock.withLock { calls += 1 }
        return result
    }
}

struct MockJournalReadinessGate: JournalReadinessChecking {
    var result: JournalReadinessResult

    func waitUntilReady(journalRoot: URL, runtime: MaterializedRuntime, timeout: Duration) async -> JournalReadinessResult {
        result
    }
}

func makeRuntime() throws -> MaterializedRuntime {
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
