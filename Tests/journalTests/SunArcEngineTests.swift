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
