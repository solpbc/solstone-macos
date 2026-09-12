// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

internal enum DiagnosticEvidenceLogEvent: Equatable, Sendable {
    case screenRecordingCDHashMismatch
    case permissionAutoStartSkipped
    case terminationCommitted(ExitReason)
    case terminationMarkerWriteFailed
    case terminationSettingsRelaunchSpawnFailed
    case terminationUpdaterInstallRecovered
    case terminationAppKitBegan
    case terminationDrainTimeout
    case deliveryWriteFailed
}

@MainActor
internal struct DiagnosticEvidenceLoggingAdapter {
    typealias Sink = @MainActor @Sendable (DiagnosticEvidenceLogEvent) -> Void

    static let live = Self()

    private let sink: Sink

    init(sink: @escaping Sink = Self.liveSink) {
        self.sink = sink
    }

    func screenRecordingCDHashMismatch() {
        sink(.screenRecordingCDHashMismatch)
    }

    func permissionAutoStartSkipped() {
        sink(.permissionAutoStartSkipped)
    }

    func terminationCommitted(reason: ExitReason) {
        sink(.terminationCommitted(reason))
    }

    func terminationMarkerWriteFailed() {
        sink(.terminationMarkerWriteFailed)
    }

    func terminationSettingsRelaunchSpawnFailed() {
        sink(.terminationSettingsRelaunchSpawnFailed)
    }

    func terminationUpdaterInstallRecovered() {
        sink(.terminationUpdaterInstallRecovered)
    }

    func terminationAppKitBegan() {
        sink(.terminationAppKitBegan)
    }

    func terminationDrainTimeout() {
        sink(.terminationDrainTimeout)
    }

    func deliveryWriteFailed() {
        sink(.deliveryWriteFailed)
    }

    private static let liveSink: Sink = { event in
        switch event {
        case .screenRecordingCDHashMismatch:
            Logger.setup.notice("screen_recording.cdhash_mismatch")
        case .permissionAutoStartSkipped:
            Logger.setup.debug("permission.auto_start_skipped")
        case .terminationCommitted(let reason):
            switch reason {
            case .ordinaryQuit:
                Logger.setup.notice("termination.committed.ordinary_quit")
            case .externalQuit:
                Logger.setup.notice("termination.committed.external_quit")
            case .settingsRestart:
                Logger.setup.notice("termination.committed.settings_restart")
            case .updaterInstall:
                Logger.setup.notice("termination.committed.updater_install")
            case .placementRepair, .journalUpdaterInstall:
                assertionFailure("non-sol exit reason reached DiagnosticEvidenceLoggingAdapter")
            }
        case .terminationMarkerWriteFailed:
            Logger.setup.error("termination.marker_write_failed")
        case .terminationSettingsRelaunchSpawnFailed:
            Logger.setup.error("termination.settings_relaunch_spawn_failed")
        case .terminationUpdaterInstallRecovered:
            Logger.setup.notice("termination.recovered.updater_install")
        case .terminationAppKitBegan:
            Logger.setup.notice("termination.appkit_began")
        case .terminationDrainTimeout:
            Logger.setup.notice("termination.drain_timeout")
        case .deliveryWriteFailed:
            Logger.setup.notice("delivery.write_failed")
        }
    }
}
