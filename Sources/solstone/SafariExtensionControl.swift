// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SafariServices
import Observation

/// Reads whether the owner has turned the solstone extension on in Safari, and
/// opens Safari's extension settings at it. Closures so tests never reach Safari.
public struct SafariExtensionControl: Sendable {
    public var readState: @Sendable (_ done: @escaping @Sendable (SafariExtensionAXState) -> Void) -> Void
    public var showSettings: @Sendable (_ done: @escaping @Sendable (Bool) -> Void) -> Void

    public init(
        readState: @escaping @Sendable (_ done: @escaping @Sendable (SafariExtensionAXState) -> Void) -> Void,
        showSettings: @escaping @Sendable (_ done: @escaping @Sendable (Bool) -> Void) -> Void
    ) {
        self.readState = readState
        self.showSettings = showSettings
    }

    // SafariServices replies on its own queue; the async forms keep Swift's
    // executor checks out of those replies.
    public static let live = SafariExtensionControl(
        readState: { done in
            Task.detached {
                let state = try? await SFSafariExtensionManager.stateOfSafariExtension(
                    withIdentifier: SafariExtensionBridge.extensionIdentifier
                )
                done(state.map { $0.isEnabled ? .on : .off } ?? .unknown)
            }
        },
        showSettings: { done in
            Task.detached {
                do {
                    try await SFSafariApplication.showPreferencesForExtension(
                        withIdentifier: SafariExtensionBridge.extensionIdentifier
                    )
                    done(true)
                } catch {
                    done(false)
                }
            }
        }
    )
}

/// Keeps a lost Safari registration visible without opening Settings. Only an
/// observed enabled choice is remembered; a deliberate disable clears it.
@MainActor
@Observable
final class SafariExtensionHealth {
    private(set) var state: SafariExtensionAXState = .unknown
    private(set) var hasChecked = false
    private(set) var expectedEnabled = false
    @ObservationIgnored private let control: SafariExtensionControl?
    @ObservationIgnored private let scheduler: PermissionPollScheduler
    @ObservationIgnored private let loadExpected: () -> Bool
    @ObservationIgnored private let saveExpected: (Bool) -> Void
    @ObservationIgnored private var cancelPolling: PermissionPollScheduler.Cancellation?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var readInFlight = false
    @ObservationIgnored private var generation = 0

    var needsAttention: Bool { hasChecked && expectedEnabled && state == .unknown }

    init(
        control: SafariExtensionControl? = .live,
        scheduler: PermissionPollScheduler = .live(interval: 60, tolerance: 5),
        loadExpected: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: "safariExtension.expectedEnabled")
        },
        saveExpected: @escaping (Bool) -> Void = { enabled in
            if enabled {
                UserDefaults.standard.set(true, forKey: "safariExtension.expectedEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "safariExtension.expectedEnabled")
            }
        }
    ) {
        self.control = control
        self.scheduler = scheduler
        self.loadExpected = loadExpected
        self.saveExpected = saveExpected
    }

    func start() {
        guard control != nil, !active else { return }
        active = true
        expectedEnabled = loadExpected()
        hasChecked = false
        cancelPolling = scheduler.armPolling { [weak self] in await self?.refresh() }
    }

    func stop() {
        active = false
        generation += 1
        cancelPolling?()
        cancelPolling = nil
        readInFlight = false
    }

    func refresh() async {
        guard active, !readInFlight, let control else { return }
        readInFlight = true
        let capturedGeneration = generation
        let next = await withCheckedContinuation { continuation in
            control.readState { continuation.resume(returning: $0) }
        }
        guard active, generation == capturedGeneration else { return }
        readInFlight = false
        switch next {
        case .on:
            if !expectedEnabled { saveExpected(true) }
            expectedEnabled = true
        case .off:
            if expectedEnabled { saveExpected(false) }
            expectedEnabled = false
        case .unknown: break
        }
        state = next
        hasChecked = true
    }
}

#endif
