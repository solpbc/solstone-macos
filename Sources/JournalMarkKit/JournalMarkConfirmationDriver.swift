// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import SolstoneCore

/// The mark question. What it draws comes from `deriveMark`, computed on this device from the CA the
/// pairing pinned, so it doesn't wait on a connection. `.unverified` means that computation failed.
@MainActor
@Observable
public final class JournalMarkConfirmationDriver {
    public enum Phase: Equatable, Sendable {
        case deriving
        case valid(JournalMark)
        case unverified
    }

    public typealias MarkDeriver = @MainActor @Sendable () async -> JournalMark?

    public var isPresented = false
    public private(set) var phase: Phase = .deriving

    @ObservationIgnored
    private var task: Task<Void, Never>?
    @ObservationIgnored
    private var activeAttemptID: UUID?
    @ObservationIgnored
    private var handledSuccessKey: String?

    public init() {}

    public func resetForNewPairAttempt() {
        task?.cancel()
        task = nil
        activeAttemptID = nil
        handledSuccessKey = nil
        phase = .deriving
        isPresented = false
    }

    public func cancel() {
        task?.cancel()
        task = nil
        activeAttemptID = nil
        phase = .deriving
        isPresented = false
    }

    public func complete() {
        task?.cancel()
        task = nil
        activeAttemptID = nil
        phase = .deriving
        isPresented = false
    }

    public func continueAnyway() {
        guard case .unverified = phase else { return }
        Logger.journalMark.info("journal-mark unverified: owner chose to continue anyway without confirmed mark")
        complete()
    }

    @discardableResult
    public func cancelPairing(
        clearConfirmedMark: @MainActor () -> Void,
        unpair: @MainActor () async -> Bool
    ) async -> Bool {
        guard case .unverified = phase else { return false }
        Logger.journalMark.info("journal-mark unverified: owner chose to cancel pairing")
        task?.cancel()
        task = nil
        activeAttemptID = nil
        guard await unpair() else { return false }
        clearConfirmedMark()
        complete()
        return true
    }

    public func confirm(setConfirmedMark: @MainActor (JournalMark) -> Void) {
        guard case .valid(let mark) = phase else { return }
        setConfirmedMark(mark)
        complete()
    }

    @discardableResult
    public func reject(
        clearConfirmedMark: @MainActor () -> Void,
        unpair: @MainActor () async -> Bool,
        onMismatch: @MainActor () -> Void
    ) async -> Bool {
        guard case .valid = phase else { return false }
        task?.cancel()
        task = nil
        activeAttemptID = nil
        guard await unpair() else { return false }
        clearConfirmedMark()
        onMismatch()
        complete()
        return true
    }

    public func startIfNeeded(for successKey: String, deriveMark: @escaping MarkDeriver) {
        guard handledSuccessKey != successKey else { return }

        handledSuccessKey = successKey
        phase = .deriving
        isPresented = true

        let attemptID = UUID()
        activeAttemptID = attemptID
        task?.cancel()
        task = Task { @MainActor [weak self, deriveMark] in
            let mark = await deriveMark()
            guard let self, !Task.isCancelled, self.activeAttemptID == attemptID else { return }
            self.task = nil
            if let mark {
                self.phase = .valid(mark)
            } else {
                Logger.journalMark.info("journal-mark unverified: the mark could not be derived")
                self.activeAttemptID = nil
                self.phase = .unverified
            }
        }
    }
}
