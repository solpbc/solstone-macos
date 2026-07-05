// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import SolstoneCore

@MainActor
@Observable
public final class JournalMarkConfirmationDriver {
    public enum Phase: Equatable {
        case connecting
        case valid(JournalMark)
    }

    public enum FallbackReason: String, Sendable {
        case heldTimeout = "held-timeout"
        case identityUnavailable = "identity-unavailable"
    }

    public enum HomeBaseResolution: Sendable, Equatable {
        case url(String)
        case held
    }

    public typealias HomeBaseResolver = @MainActor @Sendable () async -> HomeBaseResolution
    public typealias MarkFetcher = @MainActor @Sendable (String) async -> JournalMark?
    public typealias FallbackLogger = @MainActor @Sendable (FallbackReason) -> Void

    public static let fallbackLogPrefix = "journal-mark fallback: proceeding without confirmed mark reason="

    public var isPresented = false
    public private(set) var phase: Phase = .connecting

    @ObservationIgnored
    private var task: Task<Void, Never>?
    @ObservationIgnored
    private var activeAttemptID: UUID?
    @ObservationIgnored
    private var handledSuccessKey: String?
    @ObservationIgnored
    private var fallbackLogged = false
    @ObservationIgnored
    private let deadlineSeconds: TimeInterval
    @ObservationIgnored
    private let heldPollInterval: Duration
    @ObservationIgnored
    private let fetchRetryInterval: Duration

    public init(
        deadlineSeconds: TimeInterval = 6,
        heldPollInterval: Duration = .milliseconds(250),
        fetchRetryInterval: Duration = .milliseconds(500)
    ) {
        self.deadlineSeconds = deadlineSeconds
        self.heldPollInterval = heldPollInterval
        self.fetchRetryInterval = fetchRetryInterval
    }

    public func resetForNewPairAttempt() {
        task?.cancel()
        task = nil
        activeAttemptID = nil
        handledSuccessKey = nil
        fallbackLogged = false
        phase = .connecting
        isPresented = false
    }

    public func cancel() {
        task?.cancel()
        task = nil
        activeAttemptID = nil
        phase = .connecting
        isPresented = false
    }

    public func complete() {
        task?.cancel()
        task = nil
        activeAttemptID = nil
        phase = .connecting
        isPresented = false
    }

    public func confirm(setConfirmedMark: @MainActor (JournalMark) -> Void) {
        guard case .valid(let mark) = phase else { return }
        setConfirmedMark(mark)
        complete()
    }

    public func reject(
        clearConfirmedMark: @MainActor () -> Void,
        unpair: @MainActor () async -> Void,
        onMismatch: @MainActor () -> Void
    ) async {
        guard case .valid = phase else { return }
        clearConfirmedMark()
        await unpair()
        onMismatch()
        complete()
    }

    public func startIfNeeded(
        for successKey: String,
        resolveHomeBase: @escaping HomeBaseResolver,
        fetchMark: @escaping MarkFetcher,
        logFallback: @escaping FallbackLogger = { reason in
            Logger.journalMark.info("journal-mark fallback: proceeding without confirmed mark reason=\(reason.rawValue, privacy: .public)")
        }
    ) {
        guard handledSuccessKey != successKey else { return }

        handledSuccessKey = successKey
        fallbackLogged = false
        phase = .connecting
        isPresented = true

        let attemptID = UUID()
        activeAttemptID = attemptID
        task?.cancel()
        task = Task { @MainActor [weak self, resolveHomeBase, fetchMark, logFallback] in
            await self?.drive(
                attemptID: attemptID,
                resolveHomeBase: resolveHomeBase,
                fetchMark: fetchMark,
                logFallback: logFallback
            )
        }
    }

    private func drive(
        attemptID: UUID,
        resolveHomeBase: HomeBaseResolver,
        fetchMark: MarkFetcher,
        logFallback: @escaping FallbackLogger
    ) async {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        var sawURL = false

        while !Task.isCancelled, Date() < deadline, activeAttemptID == attemptID {
            switch await resolveHomeBase() {
            case .held:
                try? await Task.sleep(for: heldPollInterval)
            case .url(let baseURL):
                sawURL = true
                if let mark = await fetchMark(baseURL), Date() < deadline {
                    guard activeAttemptID == attemptID, !Task.isCancelled else { return }
                    phase = .valid(mark)
                    return
                }
                try? await Task.sleep(for: fetchRetryInterval)
            }
        }

        guard !Task.isCancelled, activeAttemptID == attemptID else { return }
        fallback(reason: sawURL ? .identityUnavailable : .heldTimeout, attemptID: attemptID, logFallback: logFallback)
    }

    private func fallback(
        reason: FallbackReason,
        attemptID: UUID,
        logFallback: FallbackLogger
    ) {
        guard activeAttemptID == attemptID, !fallbackLogged else { return }
        fallbackLogged = true
        logFallback(reason)
        task = nil
        activeAttemptID = nil
        phase = .connecting
        isPresented = false
    }
}
