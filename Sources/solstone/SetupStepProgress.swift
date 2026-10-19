// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum SetupStepProgress {
    struct Value: Equatable {
        var index: Int
        var count: Int
    }

    static func value(phase: SetupPhase) -> Value? {
        switch phase {
        case .journal:
            return nil
        case .microphone:
            return Value(index: 5, count: 7)
        case .screen:
            return Value(index: 6, count: 7)
        case .connection:
            return Value(index: 7, count: 7)
        }
    }
}
