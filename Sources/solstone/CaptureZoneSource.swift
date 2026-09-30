// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct CaptureZoneSource: Sendable {
    public static let device = CaptureZoneSource {
        NSTimeZone.resetSystemTimeZone()
        return TimeZone.current
    }

    private let read: @Sendable () throws -> TimeZone

    public init(_ read: @escaping @Sendable () throws -> TimeZone) {
        self.read = read
    }

    public func currentTimeZone() throws -> TimeZone {
        try read()
    }
}
