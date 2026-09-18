// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import SolstoneCore

@MainActor
@Observable
public final class JournalMarkConfirmationDriver {
    public enum Phase: Equatable, Sendable {
        case connecting
        case valid(JournalMark)
        case unverified(FallbackReason)
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

    public var isPresented = false
    public private(set) var phase: Phase = .connecting

    @ObservationIgnored
    private var task: Task<Void, Never>?
    @ObservationIgnored
    private var activeAttemptID: UUID?
    @ObservationIgnored
    private var handledSuccessKey: String?
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

    public func continueAnyway() {
        guard case .unverified = phase else { return }
        Logger.journalMark.info("journal-mark unverified: owner chose to continue anyway without confirmed mark")
        complete()
    }

    public func cancelPairing(
        clearConfirmedMark: @MainActor () -> Void,
        unpair: @MainActor () async -> Void
    ) async {
        guard case .unverified = phase else { return }
        Logger.journalMark.info("journal-mark unverified: owner chose to cancel pairing")
        clearConfirmedMark()
        await unpair()
        complete()
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
        fetchMark: @escaping MarkFetcher
    ) {
        guard handledSuccessKey != successKey else { return }

        handledSuccessKey = successKey
        phase = .connecting
        isPresented = true

        let attemptID = UUID()
        activeAttemptID = attemptID
        task?.cancel()
        task = Task { @MainActor [weak self, resolveHomeBase, fetchMark] in
            await self?.drive(
                attemptID: attemptID,
                resolveHomeBase: resolveHomeBase,
                fetchMark: fetchMark
            )
        }
    }

    private func drive(
        attemptID: UUID,
        resolveHomeBase: HomeBaseResolver,
        fetchMark: MarkFetcher
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
                    guard activeAttemptID == attemptID, !Task.isCancelled, phase == .connecting else { return }
                    phase = .valid(mark)
                    return
                }
                try? await Task.sleep(for: fetchRetryInterval)
            }
        }

        guard !Task.isCancelled, activeAttemptID == attemptID, phase == .connecting else { return }
        let reason: FallbackReason = sawURL ? .identityUnavailable : .heldTimeout
        enterUnverified(reason: reason, attemptID: attemptID)
    }

    private func enterUnverified(
        reason: FallbackReason,
        attemptID: UUID
    ) {
        guard activeAttemptID == attemptID else { return }
        Logger.journalMark.info("journal-mark unverified: could not confirm mark in time reason=\(reason.rawValue, privacy: .public)")
        task = nil
        activeAttemptID = nil
        phase = .unverified(reason)
        isPresented = true
    }
}
