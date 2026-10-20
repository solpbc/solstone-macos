// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum SetupBack {
    static func destination(from phase: SetupPhase) -> SetupPhase? {
        switch phase {
        case .journal, .microphone:
            return nil
        case .screen:
            return .microphone
        case .connection:
            return .screen
        }
    }
}
