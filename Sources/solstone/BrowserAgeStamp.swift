// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
import Darwin
import Foundation

/// A local elapsed-time coordinate, valid only within one boot session.
public struct BrowserAgeStamp: Sendable {
    public let bootID: String
    public let elapsedMs: UInt64

    public init(bootID: String, elapsedMs: UInt64) {
        self.bootID = bootID
        self.elapsedMs = elapsedMs
    }

    private static let bootID: String? = {
        var buffer = [CChar](repeating: 0, count: 64)
        var size = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0,
              size > 1, size <= buffer.count else { return nil }
        let value = String(decoding: buffer.prefix(size).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return UUID(uuidString: value)?.uuidString
    }()

    static func wallMilliseconds(_ date: Date) -> UInt64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value > 0 else { return 0 }
        guard value < Double(Int64.max) else { return UInt64(Int64.max) }
        return UInt64(value)
    }

    static func current() -> Self? {
        guard let bootID else { return nil }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return nil }
        // Unlike absolute time, this counter also advances while the Mac sleeps.
        let milliseconds = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int64.max) else { return nil }
        return Self(bootID: bootID, elapsedMs: UInt64(milliseconds))
    }
}
#endif
