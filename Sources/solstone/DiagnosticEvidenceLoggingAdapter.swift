// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

internal enum DiagnosticEvidenceLogEvent: Equatable, Sendable {
    case screenRecordingCDHashMismatch
    case permissionAutoStartSkipped
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

    private static let liveSink: Sink = { event in
        switch event {
        case .screenRecordingCDHashMismatch:
            Logger.setup.notice("screen_recording.cdhash_mismatch")
        case .permissionAutoStartSkipped:
            Logger.setup.debug("permission.auto_start_skipped")
        }
    }
}
