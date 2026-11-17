// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum FolderSyncAnswer: Equatable, Sendable {
    case delivered, invalid, ahead, retry
}

protocol FolderSyncJournalTransport: Sendable {
    func capabilities(serverURL: String) async throws -> [String]
}

extension UploadClient: FolderSyncJournalTransport {
    func capabilities(serverURL: String) async throws -> [String] {
        try await journalCapabilities(serverURL: serverURL)
    }
}

struct FolderSyncCapability: Sendable {
    enum Policy: Sendable {
        case everyPass
        case untilSupported(recheck: TimeInterval)
    }

    let name: String
    let policy: Policy
    private(set) var supported: Bool?
    private var checkedAt: Date?

    init(_ name: String, policy: Policy) {
        self.name = name
        self.policy = policy
    }

    func needsCheck(at now: Date) -> Bool {
        switch policy {
        case .everyPass:
            return true
        case .untilSupported(let recheck):
            return supported != true && (checkedAt.map { now.timeIntervalSince($0) >= recheck } ?? true)
        }
    }

    func check(using journal: any FolderSyncJournalTransport, serverURL: String) async throws -> Bool {
        try await journal.capabilities(serverURL: serverURL).contains(name)
    }

    mutating func record(_ listed: Bool, at now: Date) {
        supported = listed
        checkedAt = now
    }

    mutating func reset() {
        supported = nil
        checkedAt = nil
    }
}

struct FolderSyncBackoff {
    let initial: TimeInterval
    let limit: TimeInterval
    private var delay: TimeInterval
    private var due = Date.distantPast

    init(initial: TimeInterval, limit: TimeInterval) {
        self.initial = initial
        self.limit = limit
        delay = initial
    }

    func isDue(at now: Date) -> Bool { now >= due }

    mutating func deferUntilRetry(from now: Date) {
        due = now.addingTimeInterval(delay)
        delay = min(delay * 2, limit)
    }

    mutating func reset() {
        delay = initial
        due = .distantPast
    }
}

/// A serial periodic worker. A nudge brings a sleeping pass forward or queues one after an
/// active pass. Restarting while a cancelled pass unwinds waits for that pass to leave.
@MainActor
final class FolderSyncWorker {
    private var operation: (@MainActor () async -> Duration?)?
    private var task: Task<Void, Never>?
    private var running = false
    private var woken = false

    func start(_ work: @escaping @MainActor () async -> Duration?) {
        guard operation == nil else { return }
        operation = work
        wake()
    }

    func stop() {
        operation = nil
        woken = false
        task?.cancel()
        if !running { task = nil }
    }

    func wake() {
        guard operation != nil else { return }
        if running {
            woken = true
        } else {
            task?.cancel()
            schedule(after: .zero)
        }
    }

    private func schedule(after delay: Duration) {
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run() async {
        guard let operation else { return }
        running = true
        let delay = await operation()
        running = false
        task = nil
        if woken, self.operation != nil {
            woken = false
            schedule(after: .zero)
        } else if let delay, self.operation != nil {
            schedule(after: delay)
        } else {
            stop()
        }
    }
}
