// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Reason screen intake failed or stopped during recording.
public enum ScreenFailureKind: String, Sendable, Equatable {
    case couldNotStart
    case stopped
}
