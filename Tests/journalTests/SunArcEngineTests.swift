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

    @Test func peakOpacityIsPointFiveFiveAndZeroOutsideTheDay() {
        // § 12: "Opacity 0.55 at the plateau; 0 outside the day."
        #expect(SunArc.peakOpacity == 0.55)
        let plateauEnvelope = SunArcEnvelope.value(at: 0.5)
        #expect(plateauEnvelope == 1)
        let midday = SunArcTime.compute(minutes: 12 * 60, riseMinutes: 6 * 60 + 30, setMinutes: 19 * 60 + 30)
        #expect(abs(midday.night) < 0.0001)
        let opacityAtMidday = SunArc.peakOpacity * plateauEnvelope * (1 - midday.night)
        #expect(abs(opacityAtMidday - 0.55) < 0.001)

        let deepNight = SunArcTime.compute(minutes: 2 * 60, riseMinutes: 6 * 60 + 30, setMinutes: 19 * 60 + 30)
        #expect(deepNight.night == 1)
    }

    @Test func nightGroundOnSurfaceCreamMatchesTheLockedToken() {
        // § 12: "ground #2E241C-class at night on cream." — and this exact value is already
        // landed in vpx/design-system/web/tokens.css (--sunarc-night-ground) and tokens.md.
        let ground = SunArcGround.nightGround(dayGroundHex: SunArc.surfaceCreamHex)
        #expect(ground == "#2E241C")
        #expect(SunArcOKLab.lightness(ofHex: ground) < 0.28)
    }

    @Test func appearanceFlipsAtGroundLightnessOneHalf() {
        // § 12: "Appearance flips at the ground's L = 0.5, once per twilight."
        #expect(SunArcGround.isDark(groundHex: SunArc.surfaceCreamHex) == false)
        let nightGround = SunArcGround.nightGround(dayGroundHex: SunArc.surfaceCreamHex)
        #expect(SunArcGround.isDark(groundHex: nightGround) == true)
    }

    @Test func glowNeverFullyDisappearsAtNight() {
        // § 12: "The glow sits at B after dusk and at A before dawn; it never vanishes at night."
        let placement = SunArcPlacement(size: Self.size, tipRadius: Self.tipRadius)
        let midnight = SunArcTime.compute(minutes: 2 * 60, riseMinutes: 6 * 60 + 30, setMinutes: 19 * 60 + 30)
        let glow = SunArcGlow.compute(time: midnight, sunPosition: placement.position(at: 0), envelope: 0, onVisible: false, placement: placement)
        #expect(glow.alpha >= SunArc.glowNightFloor - 0.0001)

        let glowRadius = SunArc.phi * Self.tipRadius
        #expect(abs(glowRadius - 654.4947484493325) / glowRadius < 0.01)
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
        // ...and the chain still produces a real pair rather than 06:30/19:30.
        let pair = SunArcSolar.pair(for: Self.june21, timeZone: longyearbyen)
        #expect(pair != SunArcSolar.fallback)
        #expect(pair.riseMinutes >= 0 && pair.riseMinutes < 1440)
        #expect(pair.setMinutes >= 0 && pair.setMinutes < 1440)
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
