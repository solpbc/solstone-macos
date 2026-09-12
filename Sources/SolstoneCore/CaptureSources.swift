// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct CaptureSources: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let screen = CaptureSources(rawValue: 1 << 0)
    public static let microphone = CaptureSources(rawValue: 1 << 1)
    public static let all: CaptureSources = [.screen, .microphone]

    public var includesScreen: Bool {
        contains(.screen)
    }

    public var includesMicrophone: Bool {
        contains(.microphone)
    }

    public var logDescription: String {
        switch (contains(.screen), contains(.microphone)) {
        case (true, true):
            return "screen+mic"
        case (true, false):
            return "screen"
        case (false, true):
            return "mic"
        case (false, false):
            return "none"
        }
    }
}
