// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit

public enum HostClock: Sendable {
    private static let timebase: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    /// Converts mach absolute ticks to seconds using mach_timebase_info.
    public static func seconds(ticks: UInt64) -> TimeInterval {
        let numer = Double(timebase.numer)
        let denom = Double(timebase.denom)
        let nanos = (Double(ticks) * numer) / denom
        return nanos / 1_000_000_000.0
    }

    /// Reads display time ticks from SCStream CMSampleBuffer attachments.
    /// Missing or non-numeric means nil. Never samples mach_absolute_time().
    public static func displayTimeTicks(from sampleBuffer: CMSampleBuffer) -> UInt64? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] else {
            return nil
        }
        return displayTimeTicks(from: attachments)
    }

    /// Reads display time ticks from SCStream CMSampleBuffer attachments.
    /// Missing or non-numeric means nil. Never samples mach_absolute_time().
    public static func displayTimeTicks(from attachments: [[SCStreamFrameInfo: Any]]?) -> UInt64? {
        guard let first = attachments?.first,
              let value = first[.displayTime] else {
            return nil
        }
        return (value as? NSNumber)?.uint64Value
    }
}
