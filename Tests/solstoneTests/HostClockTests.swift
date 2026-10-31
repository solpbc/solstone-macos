// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("HostClock")
struct HostClockTests {
    @Test func displayTimeTicksFromAttachments() {
        let sampleTicks: UInt64 = 987_654_321
        let validAttachments: [[SCStreamFrameInfo: Any]] = [
            [.displayTime: NSNumber(value: sampleTicks)]
        ]
        #expect(HostClock.displayTimeTicks(from: validAttachments) == sampleTicks)

        let emptyAttachments: [[SCStreamFrameInfo: Any]] = []
        #expect(HostClock.displayTimeTicks(from: emptyAttachments) == nil)
        #expect(HostClock.displayTimeTicks(from: nil) == nil)

        let nonNumeric: [[SCStreamFrameInfo: Any]] = [
            [.displayTime: "not-a-number"]
        ]
        #expect(HostClock.displayTimeTicks(from: nonNumeric) == nil)
    }

    @Test func tickConversionAccuracy() {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let oneSecondTicks = UInt64((1_000_000_000.0 * Double(info.denom)) / Double(info.numer))

        let nowTicks = mach_absolute_time()
        let oneSecondAgoTicks = nowTicks >= oneSecondTicks ? nowTicks - oneSecondTicks : 0

        let nowSec = HostClock.seconds(ticks: nowTicks)
        let pastSec = HostClock.seconds(ticks: oneSecondAgoTicks)
        let diff = nowSec - pastSec

        // Converted difference should be within 1 ms of 1.0 second
        #expect(abs(diff - 1.0) < 0.001)
    }

    @Test func pollBoundsWithinTenMilliseconds() {
        let t1 = mach_absolute_time()
        usleep(5_000) // 5 ms sleep
        let t2 = mach_absolute_time()

        let elapsed = HostClock.seconds(ticks: t2) - HostClock.seconds(ticks: t1)
        // Elapsed should be between 4 ms and 15 ms, well within 10 ms of real mach_absolute_time() around the call
        #expect(elapsed >= 0.004)
        #expect(elapsed <= 0.020)
    }
}
