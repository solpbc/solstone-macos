// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

/// The sun, all day — time-of-day background pattern.
///
/// Ported from `cmo/brand/sbis/patterns/sun-arc/{index.md,sunarc.js}` in the extro repo
/// (founder lock 2026-09-19, amended 2026-09-23: the day in both appearances). Vendor the
/// reference math (`SUNARC.both()`); do not re-derive it from the token constants alone.
/// Section numbers below (§3, §4, §4a, §6, §7, §8a) refer to that spec; constant names follow
/// `vpx/design-system/tokens.md` § the sun, all day.
public enum SunArc {
    public static let phi: Double = 1.618_033_988_7
    public static let bow: Double = 0.079_19               // sagitta ÷ chord, §3
    public static let peakOpacity: Double = 0.55            // §2 the sun's plateau on a light ground
    public static let peakOpacityDark: Double = 0.20        // §8a the same lightness step on a dark ground
    public static let envelopeEdge: Double = 0.22           // §4 rise·hold·set
    public static let twilightMinutes: Double = 30
    public static let glowDayAlpha: Double = 0.22           // §7 the day halo, × env × (1 − night)
    public static let twilightRadiusRatio: Double = phi * phi   // §7 the twilight glow's radius, × R
    public static let twilightAlphaDark: Double = 0.62      // §7 × the twilight weight w
    public static let twilightAlphaLight: Double = 0.95     // §7 × the twilight weight w
    public static let twilightSink: Double = 0.10           // §4a the hidden sun's path runs to t ∈ [−0.10, 1.10]
    public static let trueDarkMinutes: Double = 180         // §4a the window about solar midnight with no glow
    public static let gradientMidStop: Double = 0.38
    public static let gradientMidRatio: Double = 0.45

    public static let goldHex = "#FFCC33"
    public static let orangeHex = "#E8913A"
    public static let sunriseHex = "#FFF3CF"                // §7 the light twilight glow's cream-gold
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
        let n = Double(civilDayOfYear(date, utcOffsetMinutes: utcOffsetMinutes))
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

        guard let rise = solar(true), let rawSet = solar(false) else { return nil }
        // Rise and set are wrapped independently into 0...1440. Above ~64° in midsummer the
        // sun sets after local midnight, so the raw set can land numerically before rise —
        // carry it onto the next day so the day's own dawn-to-dusk axis stays continuous
        // (`SunArcTime.compute` reads minutes on this same extended axis).
        let set = rawSet < rise ? rawSet + 1440 : rawSet
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
        var probe = date
        for _ in 0...polarLookbackDays {
            // Recompute the offset for every probed date, not once for `date` — a lookback
            // that spans a daylight-saving boundary must use each day's own offset, or a
            // probe on the far side of the boundary is skewed by an hour.
            let offset = Double(timeZone.secondsFromGMT(for: probe)) / 60
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

    /// The ordinal day of the passed timezone's civil date — not the UTC date, which can be a
    /// different calendar day near midnight for any offset that isn't ~0. `utcOffsetMinutes`
    /// (already resolved by the caller for this instant) is enough to build that civil
    /// calendar directly, without needing the zone's IANA identifier here.
    private static func civilDayOfYear(_ date: Date, utcOffsetMinutes: Double) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: Int(utcOffsetMinutes * 60)) ?? .gmt
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

/// §4 — the day's own clock: the arc parameter `t` and night (0…1), plus the minute read on the
/// day's own dawn-to-dusk axis (`axisMinutes`, see below) that §4a's twilight weight reuses.
public struct SunArcTime: Sendable, Equatable {
    public let t: Double
    public let night: Double
    public let axisMinutes: Double

    public static func compute(
        minutes m: Double,
        riseMinutes rise: Double,
        setMinutes set: Double,
        twilightMinutes tw: Double = SunArc.twilightMinutes
    ) -> SunArcTime {
        let dawn = rise - tw, dusk = set + tw

        // `set` (and so `dusk`) may already have been carried past 1440 by `SunArcSolar.times`
        // when the sun sets after local midnight. `m` is always given as this calendar day's
        // own minutes-since-midnight, so a small `m` that falls before the wrapped-back dusk
        // is really the tail of tonight's dusk, not tomorrow's pre-dawn night — read it on the
        // same extended axis dusk is already on, so day progress keeps moving forward through
        // midnight instead of resetting to "before dawn".
        let m2 = (dusk > 1440 && m < dusk - 1440) ? m + 1440 : m

        let t = (m2 - dawn) / (dusk - dawn)

        let night: Double
        if m2 < dawn { night = 1 }
        else if m2 < rise { night = 1 - (m2 - dawn) / tw }
        else if m2 <= set { night = 0 }
        else if m2 < dusk { night = (m2 - set) / tw }
        else { night = 1 }

        return SunArcTime(t: t, night: night, axisMinutes: m2)
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

    /// OKLab lightness of a hex colour. §6: every light ground sits above L 0.5 and every dark
    /// ground below it, which is why content never flips (asserted by the tests, not used to flip).
    public static func lightness(ofHex hex: String) -> Double {
        toOKLab(rgb(fromHex: hex)).l
    }
}


/// §2, §6 — the owner's appearance. It is the system's light/dark setting, read by the view that
/// draws the pattern and passed in; nothing in this engine derives it from the time of day,
/// and nothing in the pattern ever sets it (2026-09-23).
public enum SunArcAppearance: String, Sendable, CaseIterable {
    case light
    case dark

    /// §6 — each appearance's three grounds: day, night (dusk → the true-dark window, the window
    /// → dawn) and true dark. `SUNARC.BOTH.grounds` in the reference.
    public var grounds: (day: String, night: String, trueDark: String) {
        switch self {
        case .light: return ("#FEFCF8", "#E9DECC", "#D7C9B0")
        case .dark: return ("#392E26", "#2E241C", "#281E17")
        }
    }

    /// §2, §8a — the sun's plateau opacity: the same OKLab lightness step on either ground.
    public var peakOpacity: Double {
        self == .dark ? SunArc.peakOpacityDark : SunArc.peakOpacity
    }
}

/// §4a — the twilight weight `w` (how much twilight glow there is), the hidden sun's extended
/// arc parameter `te`, and `x`, how far into the evening (or before the dawn) the clock is.
/// `A.twilight` + `A.deepWindow` in the reference.
public struct SunArcTwilight: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case day
        case evening
        case trueDark
        case beforeDawn
    }

    public let w: Double
    public let te: Double
    public let x: Double
    public let phase: Phase

    /// `time` is `SunArcTime.compute(...)` for the same minute, rise and set: its `axisMinutes`
    /// carries the sunset-after-midnight axis, so this reads the evening on the same axis the
    /// arc does. `envelope` is `SunArcEnvelope.value(at: time.t)`.
    public static func compute(
        time: SunArcTime,
        riseMinutes rise: Double,
        setMinutes set: Double,
        envelope: Double,
        trueDarkMinutes: Double = SunArc.trueDarkMinutes,
        sink: Double = SunArc.twilightSink,
        twilightMinutes tw: Double = SunArc.twilightMinutes
    ) -> SunArcTwilight {
        let dawn = rise - tw, dusk = set + tw, m = time.axisMinutes
        if m >= dawn, m <= dusk {
            return SunArcTwilight(w: 1 - envelope, te: time.t, x: 0, phase: .day)
        }
        // The night, as minutes past dusk, and its length — both wrapped onto one day, as the
        // reference does. The true-dark window keeps an hour either side of it for the glow to
        // ease out and back in (`trueDarkHalf`); a white night has no window. Each ease branch
        // requires a non-zero length, so neither division below can be by zero.
        //
        // `m` is `time.axisMinutes`, the day's own extended axis: on a day whose sunset falls
        // after local midnight, 00:00 up to dusk is still the day (canon since extro e56d376260).
        let span = wrap(dawn - dusk), ms = wrap(m - dusk)
        let mid = span / 2, half = trueDarkHalf(span: span, trueDarkMinutes: trueDarkMinutes)
        let dS = mid - half, dE = mid + half
        if ms <= dS, dS > 0 {
            let x = ms / dS
            return SunArcTwilight(w: ease(x), te: 1 + sink * x, x: x, phase: .evening)
        }
        if ms >= dE, span > dE {
            let x = (span - ms) / (span - dE)
            return SunArcTwilight(w: ease(x), te: -sink * x, x: x, phase: .beforeDawn)
        }
        return SunArcTwilight(w: 0, te: ms < mid ? 1 + sink : -sink, x: 1, phase: .trueDark)
    }

    /// §4a — the true-dark window, as local minutes in 0..<1440: centred on the midpoint of dusk
    /// and the next dawn (= of sunset and the next sunrise).
    public static func trueDarkWindow(
        riseMinutes rise: Double,
        setMinutes set: Double,
        trueDarkMinutes: Double = SunArc.trueDarkMinutes,
        twilightMinutes tw: Double = SunArc.twilightMinutes
    ) -> (from: Double, to: Double, mid: Double) {
        let set = set < rise ? set + 1440 : set
        let dusk = set + tw, dawn = rise - tw
        let span = wrap(dawn - dusk), mid = dusk + span / 2, half = trueDarkHalf(span: span, trueDarkMinutes: trueDarkMinutes)
        return (wrap(mid - half), wrap(mid + half), wrap(mid))
    }

    /// §4a — half the true-dark window for a night of `span` minutes (dusk to the next dawn):
    /// `max(0, min(180, span − 120)) / 2`. The glow always keeps an hour to ease out after dusk
    /// and an hour to ease back in before dawn; a night shorter than two hours has no true dark.
    /// `A.deepHalf` in the reference.
    public static func trueDarkHalf(span: Double, trueDarkMinutes: Double = SunArc.trueDarkMinutes) -> Double {
        max(0, min(trueDarkMinutes, span - 120)) / 2
    }

    /// Holds, then eases to 0: `(1 − x²)^1.5`, x clamped to 0…1.
    private static func ease(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return pow(1 - c * c, 1.5)
    }

    private static func wrap(_ v: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: 1440)
        return r < 0 ? r + 1440 : r
    }
}

/// §6 — the ground: day → night linear across each twilight window, then night → true dark by
/// `1 − w`, all mixed in OKLab.
public enum SunArcGround {
    public static func ground(appearance: SunArcAppearance, night: Double, twilightWeight w: Double) -> String {
        let g = appearance.grounds
        let dayToNight = SunArcOKLab.mix(g.day, g.night, night)
        return SunArcOKLab.mix(dayToNight, g.trueDark, night * (1 - w))
    }
}

/// §7 — one radial glow: stops `a → 0.45a → 0` at 0 / 38 / 100 % of `radius`, centred on
/// `center`. Drawn under the sun, over the ground; never applied to the mark itself.
public struct SunArcGlow: Sendable, Equatable {
    public let center: CGPoint
    public let radius: Double
    public let alpha: Double
    public let colorHex: String

    /// The glow's alpha at a point — `A.glowAt` in the reference.
    public func alpha(at point: CGPoint) -> Double {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        let f = (dx * dx + dy * dy).squareRoot() / radius
        if f >= 1 { return 0 }
        if f <= SunArc.gradientMidStop { return alpha * (1 - (1 - SunArc.gradientMidRatio) * f / SunArc.gradientMidStop) }
        return alpha * SunArc.gradientMidRatio * (1 - (f - SunArc.gradientMidStop) / (1 - SunArc.gradientMidStop))
    }
}

/// One frame of the pattern — `SUNARC.both()` at its defaults, as a pure function of
/// `(W, H, minutes, sunrise, sunset, appearance)` (§10). The appearance is an input, never an
/// output: this is the whole rule a surface draws.
public struct SunArcFrame: Sendable {
    public let time: SunArcTime
    public let envelope: Double
    public let twilight: SunArcTwilight
    public let groundHex: String
    /// The sun is drawn while `−0.02 < t < 1.02` (§4).
    public let sunVisible: Bool
    public let sunCenter: CGPoint
    /// Tip to tip, `φ × min(W, H)`.
    public let sunDiameter: Double
    public let sunOpacity: Double
    /// The day halo on the sun (gold, φR), while the sun is up and it is not full night.
    public let halo: SunArcGlow?
    /// The twilight glow (φ²R at the hidden sun's `P(te)`), while `w > 0.001`.
    public let twilightGlow: SunArcGlow?

    public static func compute(
        size: CGSize,
        minutes: Double,
        riseMinutes rise: Double,
        setMinutes set: Double,
        appearance: SunArcAppearance
    ) -> SunArcFrame {
        let side = Double(min(size.width, size.height))
        let diameter = SunArc.phi * side
        let tipRadius = diameter / 2
        let placement = SunArcPlacement(size: size, tipRadius: tipRadius)

        // one extended minute axis, as the reference: a sunset wrapped below sunrise is carried
        // past 1440 (`SunArcSolar.times` already does this; a caller passing a raw pair gets the same)
        let set = set < rise ? set + 1440 : set
        let time = SunArcTime.compute(minutes: minutes, riseMinutes: rise, setMinutes: set)
        let envelope = SunArcEnvelope.value(at: time.t)
        let twilight = SunArcTwilight.compute(time: time, riseMinutes: rise, setMinutes: set, envelope: envelope)
        let ground = SunArcGround.ground(appearance: appearance, night: time.night, twilightWeight: twilight.w)

        let visible = time.t > -0.02 && time.t < 1.02
        let center = placement.position(at: min(1, max(0, time.t)))
        // (The reference's extra `× (1 − night)` at t ≤ 0 / t ≥ 1 is a no-op, since the envelope
        // is already 0 at both ends; it is left out.)
        let opacity = visible ? appearance.peakOpacity * envelope * (1 - time.night) : 0

        var halo: SunArcGlow?
        if time.night < 1, visible {
            halo = SunArcGlow(
                center: center,
                radius: SunArc.phi * tipRadius,
                alpha: SunArc.glowDayAlpha * envelope * (1 - time.night),
                colorHex: SunArc.goldHex
            )
        }

        var twilightGlow: SunArcGlow?
        if twilight.w > 0.001 {
            let color = appearance == .dark
                ? SunArcOKLab.mix(SunArc.goldHex, SunArc.orangeHex, 0.30 + 0.50 * twilight.x)
                : SunArcOKLab.mix(SunArc.sunriseHex, SunArc.goldHex, 0.45 + 0.25 * twilight.x)
            twilightGlow = SunArcGlow(
                center: placement.position(at: twilight.te),
                radius: SunArc.twilightRadiusRatio * tipRadius,
                alpha: (appearance == .dark ? SunArc.twilightAlphaDark : SunArc.twilightAlphaLight) * twilight.w,
                colorHex: color
            )
        }

        return SunArcFrame(
            time: time,
            envelope: envelope,
            twilight: twilight,
            groundHex: ground,
            sunVisible: visible,
            sunCenter: center,
            sunDiameter: diameter,
            sunOpacity: opacity,
            halo: halo,
            twilightGlow: twilightGlow
        )
    }
}
