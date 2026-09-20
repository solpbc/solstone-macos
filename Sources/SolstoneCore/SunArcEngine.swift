// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

/// The sun, all day — time-of-day background pattern.
///
/// Ported from `cmo/brand/sbis/patterns/sun-arc/{index.md,sunarc.js}` in the extro repo
/// (founder lock 2026-09-19). Vendor the reference math; do not re-derive it from the token
/// constants alone. Section numbers below (§3, §4, §6, §7) refer to that spec.
public enum SunArc {
    public static let phi: Double = 1.618_033_988_7
    public static let bow: Double = 0.079_19               // sagitta ÷ chord, §3
    public static let peakOpacity: Double = 0.55
    public static let envelopeEdge: Double = 0.22           // §4 rise·hold·set
    public static let twilightMinutes: Double = 30
    public static let nightMixInk: Double = 0.90            // §6 ground → ink
    public static let nightMixWarm: Double = 0.45           // §6 ink-mixed-ground → warm-dark (effective)
    public static let glowDayAlpha: Double = 0.22
    public static let glowNightAlpha: Double = 0.40
    public static let glowNightFloor: Double = 0.12         // §7 effective floor (dial 0.40 × 0.30)
    public static let gradientMidStop: Double = 0.38
    public static let gradientMidRatio: Double = 0.45
    public static let appearanceFlipL: Double = 0.5         // §6 OKLab lightness threshold

    public static let inkHex = "#1A1A1A"
    public static let warmDarkHex = "#2E1906"
    public static let goldHex = "#FFCC33"
    public static let orangeHex = "#E8913A"
    public static let surfaceCreamHex = "#FEFCF8"

    /// §5 rung 3, last resort — only for a zone identifier the bundled tzdb table does not
    /// know. Rungs 1 and 2 are `SunArcSolar.pair(for:)`.
    public static let fallbackRiseMinutes: Double = 6 * 60 + 30
    public static let fallbackSetMinutes: Double = 19 * 60 + 30
}

/// §5 — sunrise and sunset, on the device, never off it. The standard sunrise equation
/// (NOAA / *Almanac for Computers*, official zenith 90.833°) run against coordinates found
/// by the spec's three rungs:
///
/// 1. a location the app already holds for its own reasons — this app holds none anywhere,
///    for any purpose, and ⛔ never asks for one for this pattern alone, so `heldLocation`
///    stays `nil` here and exists for a surface that genuinely holds one;
/// 2. the system timezone's tzdb reference point (`SunArcZonePoints`, bundled with the build);
/// 3. 06:30 / 19:30 for a zone identifier the table does not know.
///
/// Nothing here reads the network or the device's location.
public enum SunArcSolar {
    public struct Pair: Sendable, Equatable {
        public let riseMinutes: Double
        public let setMinutes: Double
        public init(riseMinutes: Double, setMinutes: Double) {
            self.riseMinutes = riseMinutes
            self.setMinutes = setMinutes
        }
    }

    /// §5 rung 3.
    public static let fallback = Pair(riseMinutes: SunArc.fallbackRiseMinutes, setMinutes: SunArc.fallbackSetMinutes)

    /// How far back `pair(for:)` will look for the last day that had a sunrise, in the polar
    /// case — half a year always reaches one.
    static let polarLookbackDays = 183

    /// Sunrise and sunset as local minutes since midnight, or `nil` in polar day or night
    /// (the sun never crosses the horizon that day).
    public static func times(
        latitude: Double,
        longitude: Double,
        date: Date,
        utcOffsetMinutes: Double
    ) -> Pair? {
        let n = Double(dayOfYearUTC(date))
        let lngHour = longitude / 15

        func solar(_ isRise: Bool) -> Double? {
            let t = n + ((isRise ? 6.0 : 18.0) - lngHour) / 24
            let meanAnomaly = 0.9856 * t - 3.289
            let mRad = meanAnomaly * .pi / 180
            let trueLongitude = wrap(meanAnomaly + 1.916 * sin(mRad) + 0.020 * sin(2 * mRad) + 282.634, 360)
            let lRad = trueLongitude * .pi / 180

            var rightAscension = wrap(atan(0.91764 * tan(lRad)) * 180 / .pi, 360)
            let lQuadrant = (trueLongitude / 90).rounded(.down) * 90
            let raQuadrant = (rightAscension / 90).rounded(.down) * 90
            rightAscension = (rightAscension + (lQuadrant - raQuadrant)) / 15

            let sinDec = 0.39782 * sin(lRad)
            let cosDec = cos(asin(sinDec))
            let latRad = latitude * .pi / 180
            let cosH = (cos(90.833 * .pi / 180) - sinDec * sin(latRad)) / (cosDec * cos(latRad))
            guard cosH <= 1, cosH >= -1 else { return nil }

            let acosDeg = acos(cosH) * 180 / .pi
            let hourAngle = (isRise ? 360 - acosDeg : acosDeg) / 15
            let localMeanTime = hourAngle + rightAscension - 0.06571 * t - 6.622
            let ut = wrap(localMeanTime - lngHour, 24)
            return wrap(ut * 60 + utcOffsetMinutes, 1440)
        }

        guard let rise = solar(true), let set = solar(false) else { return nil }
        return Pair(riseMinutes: rise, setMinutes: set)
    }

    /// The pair to draw today's arc from, walking the §5 rungs in order.
    ///
    /// In polar day or night the spec says to hold the last valid pair; this finds it by
    /// walking back to the most recent day that has one, so a cold launch inside the polar
    /// night behaves exactly like a session that ran through the polar sunset.
    public static func pair(
        for date: Date,
        heldLocation: (latitude: Double, longitude: Double)? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Pair {
        guard let coords = heldLocation ?? SunArcZonePoints.point(for: timeZone.identifier) else {
            return fallback
        }
        let offset = Double(timeZone.secondsFromGMT(for: date)) / 60
        var probe = date
        for _ in 0...polarLookbackDays {
            if let found = times(latitude: coords.latitude, longitude: coords.longitude, date: probe, utcOffsetMinutes: offset) {
                return found
            }
            probe = probe.addingTimeInterval(-86_400)
        }
        return fallback
    }

    private static func wrap(_ v: Double, _ modulus: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: modulus)
        return r < 0 ? r + modulus : r
    }

    private static func dayOfYearUTC(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.ordinality(of: .day, in: .year, for: date) ?? 1
    }
}

/// §3 — the sun's position on its 36° arc between the dawn corner (top-left) and the dusk
/// corner (bottom-right), for a surface of a given size and the sun's tip radius `R`.
public struct SunArcPlacement: Sendable {
    public let a: CGPoint
    public let b: CGPoint
    public let chord: Double
    public let sagitta: Double
    public let arcRadius: Double
    public let center: CGPoint
    private let thetaA: Double
    private let delta: Double

    public init(size: CGSize, tipRadius: Double) {
        let w = Double(size.width), h = Double(size.height)
        let k = tipRadius / 2.0.squareRoot()
        let a = CGPoint(x: -k, y: -k)
        let b = CGPoint(x: w + k, y: h + k)
        self.a = a
        self.b = b

        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let c = (dx * dx + dy * dy).squareRoot()
        self.chord = c
        let ux = dx / c, uy = dy / c
        let mx = (Double(a.x) + Double(b.x)) / 2, my = (Double(a.y) + Double(b.y)) / 2

        let s = SunArc.bow * c
        self.sagitta = s
        // the normal to the chord whose y-component is negative — toward the top of the frame.
        var nx = -uy, ny = ux
        if ny > 0 { nx = -nx; ny = -ny }

        let rarc = c * c / (8 * s) + s / 2
        self.arcRadius = rarc
        let ox = mx - nx * (rarc - s), oy = my - ny * (rarc - s)
        let center = CGPoint(x: ox, y: oy)
        self.center = center

        self.thetaA = atan2(Double(a.y) - oy, Double(a.x) - ox)
        let thetaB = atan2(Double(b.y) - oy, Double(b.x) - ox)
        var d = thetaB - thetaA
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        self.delta = d
    }

    /// The sun's centre at time `t` (unclamped — the caller decides visibility at t < 0 / t > 1).
    public func position(at t: Double) -> CGPoint {
        let theta = thetaA + delta * t
        return CGPoint(x: center.x + arcRadius * cos(theta), y: center.y + arcRadius * sin(theta))
    }
}

/// §4 — the day's own clock: dawn/dusk, the arc parameter `t`, night (0…1), and night progress `q`.
public struct SunArcTime: Sendable, Equatable {
    public let t: Double
    public let night: Double
    public let q: Double

    public static func compute(
        minutes m: Double,
        riseMinutes rise: Double,
        setMinutes set: Double,
        twilightMinutes tw: Double = SunArc.twilightMinutes
    ) -> SunArcTime {
        let dawn = rise - tw, dusk = set + tw
        let t = (m - dawn) / (dusk - dawn)

        let night: Double
        if m < dawn { night = 1 }
        else if m < rise { night = 1 - (m - dawn) / tw }
        else if m <= set { night = 0 }
        else if m < dusk { night = (m - set) / tw }
        else { night = 1 }

        let nightLen = 1440 - (dusk - dawn)
        let q: Double
        if m >= dusk { q = (m - dusk) / nightLen }
        else if m < dawn { q = (m + 1440 - dusk) / nightLen }
        else { q = 0 }

        return SunArcTime(t: t, night: night, q: q)
    }
}

/// §4 — brightness envelope: sine rise, full hold, sine set, over the first/last `edge` of the path.
public enum SunArcEnvelope {
    public static func value(at t: Double, edge: Double = SunArc.envelopeEdge) -> Double {
        let u = min(1, max(0, t))
        if u < edge { return sin(u / edge * .pi / 2) }
        if u > 1 - edge { return sin((1 - u) / edge * .pi / 2) }
        return 1
    }
}

/// §6 — OKLab colour mixing (Björn Ottosson's OKLab). `Color.mix` on Apple platforms blends in
/// sRGB, which is not what the spec's ground formula calls for.
public enum SunArcOKLab {
    public struct RGB: Sendable { public let r: Double; public let g: Double; public let b: Double }

    public static func rgb(fromHex hex: String) -> RGB {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    public static func hex(fromRGB rgb: RGB) -> String {
        func byte(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(rgb.r), byte(rgb.g), byte(rgb.b))
    }

    private static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.003_130_8 ? c * 12.92 : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
    }

    private static func toOKLab(_ rgb: RGB) -> (l: Double, a: Double, b: Double) {
        let r = srgbToLinear(rgb.r), g = srgbToLinear(rgb.g), b = srgbToLinear(rgb.b)
        let l = 0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b
        let m = 0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b
        let s = 0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (
            0.210_454_255_3 * l_ + 0.793_617_785_0 * m_ - 0.004_072_046_8 * s_,
            1.977_998_495_1 * l_ - 2.428_592_205_0 * m_ + 0.450_593_709_9 * s_,
            0.025_904_037_1 * l_ + 0.782_771_766_2 * m_ - 0.808_675_766_0 * s_
        )
    }

    private static func fromOKLab(_ lab: (l: Double, a: Double, b: Double)) -> RGB {
        let l_ = lab.l + 0.396_337_777_4 * lab.a + 0.215_803_757_3 * lab.b
        let m_ = lab.l - 0.105_561_345_8 * lab.a - 0.063_854_172_8 * lab.b
        let s_ = lab.l - 0.089_484_177_5 * lab.a - 1.291_485_548_0 * lab.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let r = 4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s
        let g = -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s
        let b = -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s
        return RGB(r: linearToSrgb(r), g: linearToSrgb(g), b: linearToSrgb(b))
    }

    /// Mix two hex colours in OKLab, `t` fraction of the way from `hex1` to `hex2`.
    public static func mix(_ hex1: String, _ hex2: String, _ t: Double) -> String {
        if t <= 0 { return hex1 }
        if t >= 1 { return hex2 }
        let a = toOKLab(rgb(fromHex: hex1)), b = toOKLab(rgb(fromHex: hex2))
        let lab = (a.l + (b.l - a.l) * t, a.a + (b.a - a.a) * t, a.b + (b.b - a.b) * t)
        return hex(fromRGB: fromOKLab(lab))
    }

    /// OKLab lightness of a hex colour — the appearance-flip threshold test (§6, L ≥ 0.5).
    public static func lightness(ofHex hex: String) -> Double {
        toOKLab(rgb(fromHex: hex)).l
    }
}

/// §6 — the ground for a given day ground and night fraction, and whether content should
/// appear light-on-dark or dark-on-light for it.
public enum SunArcGround {
    /// The night ground for a given day ground, per §6's mix.
    public static func nightGround(dayGroundHex: String) -> String {
        let inkMixed = SunArcOKLab.mix(dayGroundHex, SunArc.inkHex, SunArc.nightMixInk)
        return SunArcOKLab.mix(inkMixed, SunArc.warmDarkHex, SunArc.nightMixWarm)
    }

    /// The ground actually showing right now, cross-faded by `night` (0 = day, 1 = night).
    public static func currentGround(dayGroundHex: String, night: Double) -> String {
        SunArcOKLab.mix(dayGroundHex, nightGround(dayGroundHex: dayGroundHex), night)
    }

    /// §6 appearance flip: dark content-scheme once the showing ground's OKLab L drops below 0.5.
    public static func isDark(groundHex: String) -> Bool {
        SunArcOKLab.lightness(ofHex: groundHex) < SunArc.appearanceFlipL
    }
}

/// §7 — the glow: a halo on the sun by day, a fading/rising corner glow by night. Never fully
/// disappears (`glowNightFloor`).
public struct SunArcGlow: Sendable {
    public let position: CGPoint
    public let alpha: Double

    public static func compute(
        time: SunArcTime,
        sunPosition: CGPoint,
        envelope: Double,
        onVisible: Bool,
        placement: SunArcPlacement
    ) -> SunArcGlow {
        if time.night < 1, onVisible {
            let alpha = SunArc.glowDayAlpha * envelope * (1 - time.night)
            return SunArcGlow(position: sunPosition, alpha: alpha)
        }
        let atB = time.q < 0.5
        let k = atB ? (1 - 2 * time.q) : (2 * time.q - 1)
        let alpha = SunArc.glowNightFloor + (SunArc.glowNightAlpha - SunArc.glowNightFloor) * pow(k, 1.6)
        return SunArcGlow(position: atB ? placement.b : placement.a, alpha: alpha)
    }
}
