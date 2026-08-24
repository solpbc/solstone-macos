// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

internal enum DiagnosticEvidenceLogEvent: Equatable, Sendable {
    case screenRecordingCDHashMismatch
    case permissionAutoStartSkipped
    case terminationCommitted
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

    func terminationCommitted() {
        sink(.terminationCommitted)
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
        case .terminationCommitted:
            Logger.setup.notice("termination.committed")
        case .terminationAppKitBegan:
            Logger.setup.notice("termination.appkit_began")
        case .terminationDrainTimeout:
            Logger.setup.notice("termination.drain_timeout")
        case .deliveryWriteFailed:
            Logger.setup.notice("delivery.write_failed")
        }
    }
}
