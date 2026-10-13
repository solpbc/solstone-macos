// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SolstoneCore

/// Capture-only logging categories. They keep the observer subsystem the shared
/// categories in SolstoneCore use, so existing log predicates still match.
extension Logger {
    static let capture = Logger(subsystem: SolstoneLogSubsystem.observer, category: "capture")
    static let audio = Logger(subsystem: SolstoneLogSubsystem.observer, category: "audio")
    static let upload = Logger(subsystem: SolstoneLogSubsystem.observer, category: "upload")
    static let storage = Logger(subsystem: SolstoneLogSubsystem.observer, category: "storage")
}

extension LoggerClassifiedLogSink {
    static let upload = LoggerClassifiedLogSink(logger: .upload)
}
