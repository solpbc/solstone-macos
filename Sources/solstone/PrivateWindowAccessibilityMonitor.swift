// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// App-lifetime availability for the opted-in private-window check. Capture keeps its own
/// fresh reads; this sample serves Settings and the menu even when intake is stopped.
@MainActor @Observable
final class PrivateWindowAccessibilityMonitor {
    typealias ReadWorks = @Sendable () async -> Bool

    private(set) var isEnabled = false
    private(set) var lastReadWorks: Bool?
    private(set) var askedThisSession = false
    private(set) var hasWorkedSinceAsking = false

    @ObservationIgnored private let readWorks: ReadWorks
    @ObservationIgnored private let scheduler: PermissionPollScheduler
    @ObservationIgnored private var cancelPolling: PermissionPollScheduler.Cancellation?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var isStopped = false

    init(
        readWorks: @escaping ReadWorks = {
            await Task.detached { AccessibilityTitleReader().health() == .working }.value
        },
        scheduler: PermissionPollScheduler = .live(interval: 2, tolerance: 0.5)
    ) {
        self.readWorks = readWorks
        self.scheduler = scheduler
    }

    var state: PrivateWindowAccessibilityState {
        guard isEnabled else { return .off }
        guard let lastReadWorks else {
            return askedThisSession && !hasWorkedSinceAsking ? .waiting : .checking
        }
        return .after(
            readWorks: lastReadWorks,
            askedThisSession: askedThisSession,
            hasWorkedSinceAsking: hasWorkedSinceAsking
        )
    }

    var needsAttention: Bool { isEnabled && lastReadWorks == false }

    /// Called by the setting before configuration starts polling, never by menu recovery.
    func prepareForOwnerEnable() {
        askedThisSession = true
        hasWorkedSinceAsking = false
        lastReadWorks = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard !isStopped, enabled != isEnabled else { return }
        generation &+= 1
        isEnabled = enabled
        lastReadWorks = nil
        cancelPolling?()
        cancelPolling = nil
        if enabled {
            let armGeneration = generation
            cancelPolling = scheduler.armPolling { [weak self] in
                await self?.readIfNeeded(generation: armGeneration)
            }
        }
    }

    func stop() {
        setEnabled(false)
        isStopped = true
    }

    private func readIfNeeded(generation readGeneration: UInt64) async {
        guard !isStopped, isEnabled, generation == readGeneration, !isReading else { return }
        isReading = true
        let works = await readWorks()
        isReading = false

        guard !isStopped, isEnabled else { return }
        guard generation == readGeneration else {
            // A cancelled arm cannot start a read. Once an obsolete read drains, however,
            // the enabled generation needs its own immediate read, without waiting for a tick.
            await readIfNeeded(generation: generation)
            return
        }
        if works { hasWorkedSinceAsking = true }
        lastReadWorks = works
    }

    deinit {
        MainActor.assumeIsolated { cancelPolling?() }
    }
}

/// The visible pane establishes a baseline when it opens or becomes visible again.
struct PrivateWindowAccessibilityAnnouncementPolicy {
    private var previous: PrivateWindowAccessibilityState?

    mutating func reset(to state: PrivateWindowAccessibilityState) { previous = state }

    mutating func observe(
        _ state: PrivateWindowAccessibilityState,
        isVisible: Bool
    ) -> String? {
        defer { previous = state }
        guard isVisible, let previous, previous != state else { return nil }
        switch state {
        case .working:
            return "private windows in Safari, Chrome, Edge and Brave are kept out of your journal"
        case .notWorking:
            return "checking Safari, Chrome, Edge and Brave is not working, so their private windows reach your journal"
        case .off, .checking, .waiting:
            return nil
        }
    }
}
