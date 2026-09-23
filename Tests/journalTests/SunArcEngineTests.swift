// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing
@testable import journal

/// Verifies the ported sun-arc geometry against numbers computed from the canonical JS kernel
/// (`cmo/brand/sbis/kernel/{sol-geo,sol-ulm}.js` + `cmo/brand/sbis/patterns/sun-arc/sunarc.js` in
/// the extro repo) at 720×500 — the one window size this app itself defines
/// (`.frame(minWidth: 720, minHeight: 500)`), used here as the § 12 acceptance render's
/// "stated representative window size."
@Suite("SunArc engine — macOS acceptance render at 720×500")
struct SunArcEngineTests {
    static let size = CGSize(width: 720, height: 500)
    static let tipRadius: Double = 404.5 // phi * min(720,500) / 2

    @Test func diameterAndTipRadiusMatchTheWorkedNumbers() {
        let side = min(Self.size.width, Self.size.height)
        let diameter = SunArc.phi * Double(side)
        #expect(abs(diameter - 809.0) < 0.05)
        #expect(abs(diameter / 2 - Self.tipRadius) < 0.05)
    }

    @Test func endsAreExactlyHiddenAtTZeroAndTOne() {
        // § 12: "At t = 0 and t = 1 no part of the sun is visible (the tip touches the corner exactly)."
        let placement = SunArcPlacement(size: Self.size, tipRadius: Self.tipRadius)
        #expect(abs(placement.a.x - (-286.0246929899585)) < 0.001)
        #expect(abs(placement.a.y - (-286.0246929899585)) < 0.001)
        #expect(abs(placement.b.x - 1006.0246929899585) < 0.001)
        #expect(abs(placement.b.y - 786.0246929899585) < 0.001)

        let atZero = placement.position(at: 0)
        let atOne = placement.position(at: 1)
        #expect(abs(atZero.x - placement.a.x) < 0.001)
        #expect(abs(atZero.y - placement.a.y) < 0.001)
        #expect(abs(atOne.x - placement.b.x) < 0.001)
        #expect(abs(atOne.y - placement.b.y) < 0.001)

        #expect(SunArcEnvelope.value(at: 0) == 0)
        #expect(SunArcEnvelope.value(at: 1) == 0)
    }

    @Test func midpointMatchesTheWorkedTableWithinOnePercent() {
        // § 12: "At t = ½ the centre matches the worked table for that frame's W × H within 1%."
        let placement = SunArcPlacement(size: Self.size, tipRadius: Self.tipRadius)
        let mid = placement.position(at: 0.5)
        let expectedX = 444.89797099934594, expectedY = 147.6797405649545
        #expect(abs(mid.x - expectedX) / abs(expectedX) < 0.01)
        #expect(abs(mid.y - expectedY) / abs(expectedY) < 0.01)

        #expect(abs(placement.chord - 1678.8929393475325) / placement.chord < 0.01)
        #expect(abs(placement.sagitta - 132.9552592816873) / placement.sagitta < 0.01)
        #expect(abs(placement.arcRadius - 2716.5058393365234) / placement.arcRadius < 0.01)
    }

    @Test func arcSubtendsThirtySixDegrees() {
        // § 12: "The arc subtends 36.0° ± 0.1° (compute 2·asin(c / 2Rarc))."
        let placement = SunArcPlacement(size: Self.size, tipRadius: Self.tipRadius)
        let degrees = 2 * asin(placement.chord / (2 * placement.arcRadius)) * 180 / .pi
        #expect(abs(degrees - 36.0) < 0.1)
    }

    @Test func peakOpacityIsPointFiveFiveOnLightPointTwoOnDarkAndZeroOutsideTheDay() {
        // § 12: "Opacity 0.55 at the plateau on a light ground and 0.20 on a dark ground; 0
        // outside the day."
        #expect(SunArc.peakOpacity == 0.55)
        #expect(SunArc.peakOpacityDark == 0.20)
        let rise = 6.0 * 60 + 30, set = 19.0 * 60 + 30
        let light = SunArcFrame.compute(size: Self.size, minutes: 13 * 60, riseMinutes: rise, setMinutes: set, appearance: .light)
        let dark = SunArcFrame.compute(size: Self.size, minutes: 13 * 60, riseMinutes: rise, setMinutes: set, appearance: .dark)
        #expect(light.envelope == 1)
        #expect(abs(light.sunOpacity - 0.55) < 0.0001)
        #expect(abs(dark.sunOpacity - 0.20) < 0.0001)
        for appearance in SunArcAppearance.allCases {
            let night = SunArcFrame.compute(size: Self.size, minutes: 2 * 60, riseMinutes: rise, setMinutes: set, appearance: appearance)
            #expect(night.time.night == 1)
            #expect(night.sunOpacity == 0)
            #expect(night.halo == nil)
        }
    }

    @Test func theSixGroundsAreTheSpecsTable() {
        // § 6 / tokens.md: sunarc.ground-light-* and sunarc.ground-dark-*.
        #expect(SunArcAppearance.light.grounds.day == "#FEFCF8")
        #expect(SunArcAppearance.light.grounds.night == "#E9DECC")
        #expect(SunArcAppearance.light.grounds.trueDark == "#D7C9B0")
        #expect(SunArcAppearance.dark.grounds.day == "#392E26")
        #expect(SunArcAppearance.dark.grounds.night == "#2E241C")
        #expect(SunArcAppearance.dark.grounds.trueDark == "#281E17")
    }

    @Test func contentNeverFlipsEveryLightGroundIsLightAndEveryDarkGroundIsDark() {
        // § 6: "every light ground sits above L 0.5 and every dark ground below it, so content
        // never flips" — checked at every minute of a Denver day, both appearances.
        let rise = 408.25991130150896, set = 1135.6484964224096
        for m in 0..<1440 {
            let light = SunArcFrame.compute(size: Self.size, minutes: Double(m), riseMinutes: rise, setMinutes: set, appearance: .light)
            let dark = SunArcFrame.compute(size: Self.size, minutes: Double(m), riseMinutes: rise, setMinutes: set, appearance: .dark)
            #expect(SunArcOKLab.lightness(ofHex: light.groundHex) > 0.5, "light ground at minute \(m)")
            #expect(SunArcOKLab.lightness(ofHex: dark.groundHex) < 0.5, "dark ground at minute \(m)")
        }
    }

    @Test func insideTheTrueDarkWindowThereIsNoGlowAndTheTrueDarkGround() {
        // § 12: "Inside the true-dark window no glow is drawn and the ground is the true-dark
        // ground." The 09-19 floor of 0.12 is retired.
        let rise = 408.25991130150896, set = 1135.6484964224096
        for appearance in SunArcAppearance.allCases {
            let frame = SunArcFrame.compute(size: Self.size, minutes: 60, riseMinutes: rise, setMinutes: set, appearance: appearance)
            #expect(frame.twilight.phase == .trueDark)
            #expect(frame.twilight.w == 0)
            #expect(frame.twilightGlow == nil)
            #expect(frame.halo == nil)
            #expect(frame.groundHex == appearance.grounds.trueDark)
        }
    }

    @Test func positionUpdatesAtMostOnceAMinuteByConstruction() {
        // § 12: "Position updates at most once a minute; no timer under a minute." — the view
        // drives its Canvas from `TimelineView(.everyMinute)`, SwiftUI's own once-a-minute
        // schedule; this asserts the minute-quantization the schedule relies on, since the
        // schedule itself isn't unit-testable headlessly.
        let a = SunArcBackgroundView.minutesSinceMidnight(Date(timeIntervalSince1970: 1_726_750_020)) // arbitrary instant (00s)
        let b = SunArcBackgroundView.minutesSinceMidnight(Date(timeIntervalSince1970: 1_726_750_050)) // +30s, same minute (30s)
        #expect(a == b)
    }
}

/// § 5's fallback chain and § 12's ninth acceptance item — *"With location denied or absent,
/// the times come from the system timezone's tzdb point, not from a fixed default."* The
/// reference day is the spec's own worked example (§ 4: Denver, 2026-09-19, rise 06:44,
/// set 19:02).
@Suite("SunArc solar — the §5 three-rung chain")
struct SunArcSolarTests {
    static let sept19 = Date(timeIntervalSince1970: 1_789_819_200) // 2026-09-19T12:00:00Z
    static let june21 = Date(timeIntervalSince1970: 1_782_043_200) // 2026-06-21T12:00:00Z
    static let denver = TimeZone(identifier: "America/Denver")!

    @Test func theBundledZoneTableCarriesTheSpecsWorkedPoint() {
        // § 5 rung 2: "America/Denver → 39.74° N, 104.98° W".
        let point = SunArcZonePoints.point(for: "America/Denver")
        #expect(point != nil)
        #expect(abs((point?.latitude ?? 0) - 39.74) < 0.005)
        #expect(abs((point?.longitude ?? 0) - (-104.98)) < 0.005)
        // tzdb 2026c zone.tab, generated by vpx/design-system/tools/gen-sun-arc-zone-points.py
        #expect(SunArcZonePoints.zoneCount == 418)
        #expect(SunArcZonePoints.point(for: "Europe/Oslo") != nil)
        #expect(SunArcZonePoints.point(for: "America/Indiana/Indianapolis") != nil)
    }

    @Test func denverSunriseAndSunsetMatchTheSpecsWorkedDay() {
        // § 4's worked table: rise 06:44, set 19:02 on 2026-09-19.
        let times = SunArcSolar.times(latitude: 39.74, longitude: -104.98, date: Self.sept19, utcOffsetMinutes: -360)
        #expect(times != nil)
        #expect(abs((times?.riseMinutes ?? 0) - Double(6 * 60 + 44)) <= 1.0)
        #expect(abs((times?.setMinutes ?? 0) - Double(19 * 60 + 2)) <= 1.0)
    }

    @Test func theSystemTimezoneIsTheSecondRungNotTheFixedDefault() {
        // § 12: "With location denied or absent, the times come from the system timezone's
        // tzdb point, not from a fixed default."
        let pair = SunArcSolar.pair(for: Self.sept19, timeZone: Self.denver)
        #expect(pair != SunArcSolar.fallback)
        #expect(abs(pair.riseMinutes - Double(6 * 60 + 44)) <= 1.0)
        #expect(abs(pair.setMinutes - Double(19 * 60 + 2)) <= 1.0)
    }

    @Test func aLocationTheAppAlreadyHoldsOutranksTheZonePoint() {
        // § 5 rung 1 ahead of rung 2. This app holds no location, so the argument is nil in
        // production — the ordering is asserted here so a surface that does hold one inherits it.
        let sydney = SunArcSolar.pair(
            for: Self.sept19,
            heldLocation: (latitude: -33.87, longitude: 151.22),
            timeZone: Self.denver
        )
        let zoneOnly = SunArcSolar.pair(for: Self.sept19, timeZone: Self.denver)
        #expect(sydney != zoneOnly)
        #expect(sydney != SunArcSolar.fallback)
    }

    @Test func aTimezoneChangeChangesTheTimes() {
        // § 5: "Recompute once a day and on a timezone or location change."
        let tokyo = SunArcSolar.pair(for: Self.sept19, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let denver = SunArcSolar.pair(for: Self.sept19, timeZone: Self.denver)
        #expect(tokyo != denver)
        #expect(tokyo != SunArcSolar.fallback)
    }

    @Test func anIdentifierTheTableDoesNotKnowTakesTheFixedDefault() {
        // § 5 rung 3: "06:30 / 19:30 only if the zone identifier is unknown to the table."
        let unknown = TimeZone(secondsFromGMT: 0)!
        #expect(SunArcZonePoints.point(for: unknown.identifier) == nil)
        let pair = SunArcSolar.pair(for: Self.sept19, timeZone: unknown)
        #expect(pair == SunArcSolar.fallback)
        #expect(pair.riseMinutes == 6 * 60 + 30)
        #expect(pair.setMinutes == 19 * 60 + 30)
    }

    @Test func polarDayHoldsTheLastValidPairRatherThanTheFixedDefault() {
        // § 5: "In polar day or night (no sunrise) hold the last valid pair."
        let longyearbyen = TimeZone(identifier: "Arctic/Longyearbyen")!
        let point = SunArcZonePoints.point(for: "Arctic/Longyearbyen")!
        let offset = Double(longyearbyen.secondsFromGMT(for: Self.june21)) / 60

        // The midsummer day itself has no sunrise at 78° N...
        #expect(SunArcSolar.times(latitude: point.latitude, longitude: point.longitude, date: Self.june21, utcOffsetMinutes: offset) == nil)
        // ...and the chain still produces a real pair rather than 06:30/19:30. `setMinutes` may
        // now exceed 1440 (a sunset carried past midnight, § the post-midnight-sunset fix
        // below) — the invariant is a sane, non-negative day length, not an arbitrary ceiling.
        let pair = SunArcSolar.pair(for: Self.june21, timeZone: longyearbyen)
        #expect(pair != SunArcSolar.fallback)
        #expect(pair.riseMinutes >= 0 && pair.riseMinutes < 1440)
        #expect(pair.setMinutes >= pair.riseMinutes)
        #expect(pair.setMinutes - pair.riseMinutes < 1440)
    }

    @Test func dayOfYearUsesTheCivilDateInTheEnginesTimezoneNotUTC() {
        // Two instants six hours apart that cross UTC midnight (Sep 18 → Sep 19) but land on
        // the SAME local calendar day (Sep 18) at UTC-10 (Honolulu-like coordinates, no DST).
        // Before the fix, `times()` derived its day-of-year from the UTC calendar day, so these
        // two calls would silently use different days (Sep 18 vs Sep 19) and disagree.
        let lat = 21.3069, lon = -157.8583, offset = -600.0
        let beforeUTCMidnight = Date(timeIntervalSince1970: 1_789_761_600) // 2026-09-18T20:00:00Z (local: Sep 18, 10:00)
        let afterUTCMidnight = Date(timeIntervalSince1970: 1_789_783_200) // 2026-09-19T02:00:00Z (local: Sep 18, 16:00)

        let a = SunArcSolar.times(latitude: lat, longitude: lon, date: beforeUTCMidnight, utcOffsetMinutes: offset)
        let b = SunArcSolar.times(latitude: lat, longitude: lon, date: afterUTCMidnight, utcOffsetMinutes: offset)
        #expect(a != nil && b != nil)
        #expect(a == b)
    }

    @Test func reykjavikMidsummerSunsetAfterMidnightKeepsDayProgressForwardAcrossMidnight() {
        // § the post-midnight-sunset fix: above ~64° in midsummer the sun sets after local
        // midnight (Reykjavik, 21 June: rise ≈ 02:54, raw wrapped set ≈ 00:03 — a smaller
        // number than rise). Uncorrected, `dusk` (set + twilight) falls before `dawn`
        // (rise − twilight), so `SunArcTime.compute`'s day fraction has a negative-length
        // denominator and reads almost the entire day as night. Corrected, the day runs
        // rise → (next-day) dusk without inverting, and progress never runs backward across
        // the midnight boundary.
        let reykjavik = (latitude: 64.1466, longitude: -21.9426)
        let offset = 0.0 // Iceland observes no daylight saving

        let pair = SunArcSolar.times(latitude: reykjavik.latitude, longitude: reykjavik.longitude, date: Self.june21, utcOffsetMinutes: offset)
        #expect(pair != nil)
        guard let pair else { return }
        #expect(abs(pair.riseMinutes - Double(2 * 60 + 55)) < 2) // ≈ 02:54
        #expect(pair.setMinutes > 1440) // carried onto the next day, not wrapped back to ≈00:03
        #expect(abs(pair.setMinutes - 1440 - Double(0 * 60 + 4)) < 2) // ≈ 00:03/00:04 the next day

        // Midday must read as day, not the "almost the whole day is night" symptom of the bug.
        let midday = SunArcTime.compute(minutes: 12 * 60, riseMinutes: pair.riseMinutes, setMinutes: pair.setMinutes)
        #expect(midday.night == 0)

        // Day progress across the midnight boundary is continuous and strictly forward, never
        // resetting or running backward: 23:59 is still day (before the ≈00:04 sunset), local
        // midnight (00:00) is still day too, and 00:10 — comfortably inside the 30-minute dusk
        // twilight that follows the true sunset instant — has started ramping into night.
        let justBeforeMidnight = SunArcTime.compute(minutes: 1439, riseMinutes: pair.riseMinutes, setMinutes: pair.setMinutes)
        let atMidnight = SunArcTime.compute(minutes: 0, riseMinutes: pair.riseMinutes, setMinutes: pair.setMinutes)
        let intoDuskTwilight = SunArcTime.compute(minutes: 10, riseMinutes: pair.riseMinutes, setMinutes: pair.setMinutes)
        #expect(justBeforeMidnight.night == 0)
        #expect(atMidnight.night == 0)
        #expect(justBeforeMidnight.t < atMidnight.t)
        #expect(atMidnight.t < intoDuskTwilight.t)
        #expect(intoDuskTwilight.night > 0 && intoDuskTwilight.night < 1)
    }

    @Test func polarLookbackRecomputesTheOffsetPerProbeDateAcrossADSTBoundary() {
        // § the polar-lookback offset fix: a lookback that spans a daylight-saving boundary
        // must use each probed date's own offset. `heldLocation` pushes the polar-night
        // threshold to early October at 85° N (real Longyearbyen, 78° N, would not need to
        // look back far enough to cross the boundary); `Arctic/Longyearbyen`'s real DST rule
        // supplies the offset. Starting 2026-11-01 (CET, UTC+1) and walking back finds
        // 2026-10-07 (CEST, UTC+2) as the last day with a real sunrise — 25 days back, crossing
        // the 2026-10-25 DST end. A single stale offset reused for every probe would apply
        // Nov 1's CET offset to Oct 7, skewing the result by a full hour.
        let longyearbyen = TimeZone(identifier: "Arctic/Longyearbyen")!
        let start = Date(timeIntervalSince1970: 1_793_534_400) // 2026-11-01T12:00:00Z
        let pole = (latitude: 85.0, longitude: 15.6267)

        let pair = SunArcSolar.pair(for: start, heldLocation: pole, timeZone: longyearbyen)
        #expect(pair != SunArcSolar.fallback)

        let oct7 = Date(timeIntervalSince1970: 1_793_534_400 - 25 * 86_400) // 2026-10-07T12:00:00Z
        let correctOffset = Double(longyearbyen.secondsFromGMT(for: oct7)) / 60
        #expect(correctOffset == 120) // CEST — still before the Oct 25 DST end

        let expected = SunArcSolar.times(latitude: pole.latitude, longitude: pole.longitude, date: oct7, utcOffsetMinutes: correctOffset)
        #expect(expected != nil)
        guard let expected else { return }
        #expect(pair == expected)

        // The bug this guards against: reusing Nov 1's CET (UTC+1) offset for the Oct 7 probe
        // would have skewed both times by exactly one hour.
        let staleOffset = Double(longyearbyen.secondsFromGMT(for: start)) / 60
        #expect(staleOffset == 60) // CET
        let stale = SunArcSolar.times(latitude: pole.latitude, longitude: pole.longitude, date: oct7, utcOffsetMinutes: staleOffset)
        #expect(stale != nil)
        guard let stale else { return }
        #expect(abs(pair.riseMinutes - stale.riseMinutes - 60) < 0.01)
    }

    @Test func theBackgroundDrawsFromTheChainNotFromTheFixedDefault() {
        // The view's own clock now moves with the zone: the same instant in two zones puts the
        // sun at two different points on its arc.
        let denverPair = SunArcSolar.pair(for: Self.sept19, timeZone: Self.denver)
        let tokyoPair = SunArcSolar.pair(for: Self.sept19, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let denverTime = SunArcTime.compute(minutes: 12 * 60, riseMinutes: denverPair.riseMinutes, setMinutes: denverPair.setMinutes)
        let tokyoTime = SunArcTime.compute(minutes: 12 * 60, riseMinutes: tokyoPair.riseMinutes, setMinutes: tokyoPair.setMinutes)
        #expect(abs(denverTime.t - tokyoTime.t) > 0.001)
    }
}

/// § 4a's worked-numbers table — `SUNARC.both()` in `sunarc.js`, Denver 2026-09-23 (rise 06:48,
/// set 18:56 as the reference's own `sunTimes` computes them, to full precision), iphone
/// 393 × 852, both appearances. Tolerances: ± 1 per channel on colours (§ 12), ± 0.001 on
/// alphas, ± 0.5 px on positions. The glow values beyond the printed table (full-precision
/// centres, the 720 × 500 frame, the window edges) come from the same function, run with node.
@Suite("SunArc both appearances — § 4a worked numbers")
struct SunArcBothAppearancesTests {
    static let iphone = CGSize(width: 393, height: 852)
    static let mac = CGSize(width: 720, height: 500)
    static let rise = 408.25991130150896
    static let set = 1135.6484964224096

    struct Row {
        let minutes: Double
        let appearance: SunArcAppearance
        let ground: String
        let sunAlpha: Double
        let w: Double
        let phase: SunArcTwilight.Phase
        /// centre x, centre y, alpha, colour — nil when no twilight glow is drawn.
        let glow: (x: Double, y: Double, a: Double, color: String)?
    }

    static let rows: [Row] = [
        Row(minutes: 780, appearance: .light, ground: "#FEFCF8", sunAlpha: 0.550, w: 0, phase: .day, glow: nil),
        Row(minutes: 780, appearance: .dark, ground: "#392E26", sunAlpha: 0.200, w: 0, phase: .day, glow: nil),
        Row(minutes: 1136, appearance: .light, ground: "#FEFCF7", sunAlpha: 0.1444, w: 0.7344, phase: .day, glow: (601.86, 1019.65, 0.6977, "#FFE296")),
        Row(minutes: 1136, appearance: .dark, ground: "#392E26", sunAlpha: 0.0525, w: 0.7344, phase: .day, glow: (601.86, 1019.65, 0.4553, "#F9BA36")),
        Row(minutes: 1181, appearance: .light, ground: "#E9DECC", sunAlpha: 0, w: 0.9937, phase: .evening, glow: (620.44, 1086.72, 0.9440, "#FFE294")),
        Row(minutes: 1181, appearance: .dark, ground: "#2E241C", sunAlpha: 0, w: 0.9937, phase: .evening, glow: (620.44, 1086.72, 0.6161, "#F8B836")),
        Row(minutes: 1320, appearance: .light, ground: "#DFD2BC", sunAlpha: 0, w: 0.4341, phase: .evening, glow: (642.28, 1176.83, 0.4124, "#FFDC7F")),
        Row(minutes: 1320, appearance: .dark, ground: "#2B2119", sunAlpha: 0, w: 0.4341, phase: .evening, glow: (642.28, 1176.83, 0.2692, "#F1A739")),
        Row(minutes: 60, appearance: .light, ground: "#D7C9B0", sunAlpha: 0, w: 0, phase: .trueDark, glow: nil),
        Row(minutes: 60, appearance: .dark, ground: "#281E17", sunAlpha: 0, w: 0, phase: .trueDark, glow: nil),
        Row(minutes: 330, appearance: .light, ground: "#E8DDCA", sunAlpha: 0, w: 0.9381, phase: .beforeDawn, glow: (-249.94, -244.96, 0.8912, "#FFE08F")),
        Row(minutes: 330, appearance: .dark, ground: "#2E241C", sunAlpha: 0, w: 0.9381, phase: .beforeDawn, glow: (-249.94, -244.96, 0.5816, "#F6B437")),
    ]

    static func frame(_ minutes: Double, _ appearance: SunArcAppearance, size: CGSize = iphone) -> SunArcFrame {
        SunArcFrame.compute(size: size, minutes: minutes, riseMinutes: rise, setMinutes: set, appearance: appearance)
    }

    static func closeHex(_ a: String, _ b: String) -> Bool {
        let x = SunArcOKLab.rgb(fromHex: a), y = SunArcOKLab.rgb(fromHex: b)
        return abs(x.r - y.r) * 255 <= 1.01 && abs(x.g - y.g) * 255 <= 1.01 && abs(x.b - y.b) * 255 <= 1.01
    }

    @Test func everyRowOfTheWorkedTable() {
        for row in Self.rows {
            let f = Self.frame(row.minutes, row.appearance)
            let label = "\(row.appearance) at \(row.minutes)"
            #expect(Self.closeHex(f.groundHex, row.ground), "\(label): ground \(f.groundHex) vs \(row.ground)")
            #expect(abs(f.sunOpacity - row.sunAlpha) < 0.001, "\(label): sun α \(f.sunOpacity)")
            #expect(abs(f.twilight.w - row.w) < 0.001, "\(label): w \(f.twilight.w)")
            #expect(f.twilight.phase == row.phase, "\(label): phase \(f.twilight.phase)")
            if let g = row.glow {
                let tg = f.twilightGlow
                #expect(tg != nil, "\(label): twilight glow missing")
                guard let tg else { continue }
                #expect(abs(Double(tg.center.x) - g.x) < 0.5 && abs(Double(tg.center.y) - g.y) < 0.5, "\(label): centre \(tg.center)")
                #expect(abs(tg.alpha - g.a) < 0.001, "\(label): alpha \(tg.alpha)")
                #expect(Self.closeHex(tg.colorHex, g.color), "\(label): colour \(tg.colorHex) vs \(g.color)")
                #expect(abs(tg.radius - 832.39) < 0.05, "\(label): radius \(tg.radius)")
            } else {
                #expect(f.twilightGlow == nil, "\(label): unexpected twilight glow")
            }
        }
    }

    @Test func theDayHaloIsUnchanged() {
        // § 7: gold, radius φR, 0.22 · env · (1 − night), centred on the sun.
        let noon = Self.frame(780, .dark)
        #expect(noon.halo?.alpha == 0.22)
        #expect(noon.halo?.colorHex == SunArc.goldHex)
        #expect(abs((noon.halo?.radius ?? 0) - SunArc.phi * noon.sunDiameter / 2) < 0.001)
        #expect(noon.halo?.center == noon.sunCenter)
        // at sunset the halo and the twilight glow are both drawn, on the same centre (te = t by day)
        let sunset = Self.frame(1136, .light)
        #expect(abs((sunset.halo?.alpha ?? 0) - 0.0578) < 0.001)
        #expect(sunset.halo?.center == sunset.sunCenter)
        #expect(abs((sunset.halo?.radius ?? 0) - SunArc.phi * sunset.sunDiameter / 2) < 0.001)
        #expect(sunset.twilightGlow?.center == sunset.sunCenter)
    }

    @Test func atDuskPlusFifteenTheCornerIsLit() {
        // § 12: at dusk + 15 min the twilight glow's alpha at the dusk-side corner is ≥ 0.25 on
        // dark and ≥ 0.40 on light (§ 4a: 0.272 · 0.416).
        let corner = CGPoint(x: Self.iphone.width, y: Self.iphone.height)
        let light = Self.frame(1181, .light).twilightGlow?.alpha(at: corner) ?? 0
        let dark = Self.frame(1181, .dark).twilightGlow?.alpha(at: corner) ?? 0
        #expect(light >= 0.40 && abs(light - 0.416) < 0.002)
        #expect(dark >= 0.25 && abs(dark - 0.272) < 0.002)
        // before dawn it sits beyond the top-left and lights that corner instead
        let dawnCorner = Self.frame(330, .dark).twilightGlow?.alpha(at: .zero) ?? 0
        #expect(abs(dawnCorner - 0.245) < 0.002)
    }

    @Test func theTrueDarkWindowIsThreeHoursAboutSolarMidnight() {
        // § 4a: 23:21–02:21 on the worked day; the glow is 0 inside it, and eases back either side.
        let window = SunArcTwilight.trueDarkWindow(riseMinutes: Self.rise, setMinutes: Self.set)
        #expect(abs(window.from - 1401.954) < 0.01)
        #expect(abs(window.to - 141.954) < 0.01)
        #expect(Self.frame(1400, .dark).twilight.w > 0.001)
        #expect(Self.frame(1400, .dark).twilightGlow != nil)
        #expect(Self.frame(1403, .dark).twilight.w == 0)
        #expect(Self.frame(140, .dark).twilight.w == 0)
        #expect(Self.frame(145, .dark).twilight.w > 0)
    }

    @Test func theMacWindowCarriesTheSameRule() {
        // This window's own minimum, 720 × 500: the glow radius and the 19:41 centre, from the
        // reference at the same size.
        let f = Self.frame(1181, .light, size: Self.mac)
        #expect(abs((f.twilightGlow?.radius ?? 0) - 1059.02) < 0.05)
        #expect(abs(Double(f.twilightGlow?.center.x ?? 0) - 1011.94) < 0.5)
        #expect(abs(Double(f.twilightGlow?.center.y ?? 0) - 795.41) < 0.5)
    }

    @Test func aSunsetAfterMidnightReadsTheEveningOnTheDaysOwnAxis() {
        // Reykjavik-like midsummer pair: rise 02:55, set 00:04 the next day (carried to 1444).
        // The oracle is `SUNARC.both()` fed the extended minute (m + 1440 while m < dusk − 1440),
        // because the reference on the raw minute reads 00:00–00:33 as "before dawn" with te ≈ 130
        // (reported to VPX, 2026-09-23). 720 × 500, dark.
        let rise = 175.0, set = 1444.0
        func f(_ m: Double) -> SunArcFrame {
            SunArcFrame.compute(size: Self.mac, minutes: m, riseMinutes: rise, setMinutes: set, appearance: .dark)
        }
        let tenPast = f(10)
        #expect(tenPast.twilight.phase == .day)
        #expect(abs(tenPast.twilight.w - 0.8714) < 0.001)
        #expect(abs(tenPast.twilight.te - 0.9819) < 0.001)
        #expect(Self.closeHex(tenPast.groundHex, "#372C24"))
        #expect(abs(Double(tenPast.twilightGlow?.center.x ?? 0) - 989.41) < 0.5)
        #expect(abs(Double(tenPast.twilightGlow?.center.y ?? 0) - 760.08) < 0.5)
        #expect(abs((tenPast.twilightGlow?.alpha ?? 0) - 0.5403) < 0.001)
        let halfPast = f(30)
        #expect(halfPast.twilight.phase == .day)
        #expect(abs(halfPast.twilight.w - 0.9785) < 0.001)
        #expect(Self.closeHex(halfPast.groundHex, "#2F251D"))
        // dusk is 00:34; the night is 111 minutes, so the window is the night less a minute
        // either side and the glow goes out between 00:34 and 00:35 (spec as written)
        let dusk = f(34)
        #expect(dusk.twilight.phase == .evening && dusk.twilight.w == 1)
        #expect(abs((dusk.twilightGlow?.alpha ?? 0) - 0.62) < 0.001)
        let oneLater = f(35)
        #expect(oneLater.twilight.w == 0 && oneLater.twilightGlow == nil)
        #expect(oneLater.groundHex == "#281E17")
        #expect(f(90).twilight.phase == .trueDark)
        #expect(f(144).twilight.w == 0)
        let dawn = f(145)
        #expect(dawn.twilight.phase == .day && dawn.twilight.w == 1)
    }

    @Test func everyMinuteStaysOnThePathForOrdinaryShortPolarAndOverlappingDays() {
        // te ∈ [−0.10, 1.10] and w ∈ [0, 1] at every minute: the negative twin of a glow flung
        // round the circle. Denver 09-23, the Reykjavik-like pair, the Longyearbyen polar-held
        // pair (rise 119.8, set 1444.9) and a synthetic pair whose dusk − dawn exceeds a day.
        let pairs: [(Double, Double)] = [(Self.rise, Self.set), (175, 1444), (119.8, 1444.9), (90, 1470)]
        for (rise, set) in pairs {
            for m in 0..<1440 {
                for appearance in SunArcAppearance.allCases {
                    let f = SunArcFrame.compute(size: Self.mac, minutes: Double(m), riseMinutes: rise, setMinutes: set, appearance: appearance)
                    let tw = f.twilight
                    #expect(tw.w.isFinite && tw.w >= 0 && tw.w <= 1, "w \(tw.w) at \(m) for \(rise)/\(set)")
                    #expect(tw.te.isFinite && tw.te >= -0.1 - 1e-9 && tw.te <= 1.1 + 1e-9, "te \(tw.te) at \(m) for \(rise)/\(set)")
                    if let g = f.twilightGlow { #expect(g.alpha >= 0 && g.alpha <= 0.95) }
                }
            }
        }
    }
}
