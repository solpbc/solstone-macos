// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCore
import SwiftUI

/// The sun, all day — the mark as this window's time-of-day background. One sun per surface
/// (§8); drawn behind all window content, never reacted to. `TimelineView(.everyMinute)`
/// recomputes position at most once a minute (§9) — the pattern has no continuous animation.
///
/// Location: this app holds no location authorization anywhere, for any purpose, and ⛔ never
/// asks for one for this pattern alone. Sunrise and sunset come from `SunArcSolar.pair(for:)`
/// — the system timezone's bundled tzdb reference point (§5 rung 2), falling to 06:30/19:30
/// only for a zone identifier the table does not know (rung 3). Both the zone and the clock
/// read `autoupdatingCurrent`, so a timezone change lands on the next minute tick without an
/// observer.
struct SunArcBackgroundView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Canvas { ctx, size in
                Self.draw(in: &ctx, size: size, date: context.date)
            }
        }
        .allowsHitTesting(false)
    }

    static func minutesSinceMidnight(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Double {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
    }

    /// The current ground colour and whether content should render dark — read by
    /// `JournalWindowSceneRoot` on the same `TimelineView(.everyMinute)` schedule so the
    /// background and the `.preferredColorScheme` flip stay in lockstep without shared state.
    static func appearance(at date: Date, dayGroundHex: String = SunArc.surfaceCreamHex) -> (groundHex: String, isDark: Bool) {
        let solar = SunArcSolar.pair(for: date)
        let time = SunArcTime.compute(
            minutes: minutesSinceMidnight(date),
            riseMinutes: solar.riseMinutes,
            setMinutes: solar.setMinutes
        )
        let ground = SunArcGround.currentGround(dayGroundHex: dayGroundHex, night: time.night)
        return (ground, SunArcGround.isDark(groundHex: ground))
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, date: Date) {
        guard size.width > 0, size.height > 0 else { return }
        let dayGroundHex = SunArc.surfaceCreamHex
        let side = min(size.width, size.height)
        let diameter = SunArc.phi * Double(side)
        let tipRadius = diameter / 2

        let solar = SunArcSolar.pair(for: date)
        let time = SunArcTime.compute(
            minutes: minutesSinceMidnight(date),
            riseMinutes: solar.riseMinutes,
            setMinutes: solar.setMinutes
        )
        let placement = SunArcPlacement(size: size, tipRadius: tipRadius)
        let clampedT = min(1, max(0, time.t))
        let position = placement.position(at: clampedT)
        let onVisible = time.t > -0.02 && time.t < 1.02
        let envelope = SunArcEnvelope.value(at: time.t)
        let opacity = onVisible ? SunArc.peakOpacity * envelope * (1 - time.night) : 0

        // ground — behind everything
        let groundHex = SunArcGround.currentGround(dayGroundHex: dayGroundHex, night: time.night)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(sunArcHex: groundHex)))

        // glow — under the sun, over the ground (§7)
        let glow = SunArcGlow.compute(time: time, sunPosition: position, envelope: envelope, onVisible: onVisible, placement: placement)
        if glow.alpha > 0.002 {
            let glowRadius = SunArc.phi * tipRadius
            let glowColor = Color(sunArcHex: SunArc.goldHex)
            let gradient = Gradient(stops: [
                .init(color: glowColor.opacity(glow.alpha), location: 0),
                .init(color: glowColor.opacity(glow.alpha * SunArc.gradientMidRatio), location: SunArc.gradientMidStop),
                .init(color: glowColor.opacity(0), location: 1)
            ])
            ctx.fill(
                Path(ellipseIn: CGRect(x: glow.position.x - glowRadius, y: glow.position.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                with: .radialGradient(gradient, center: glow.position, startRadius: 0, endRadius: glowRadius)
            )
        }

        // the sun — one graphic (§8), never redrawn: the mark, scaled and translated (§10)
        guard onVisible, opacity > 0.001 else { return }
        ctx.drawLayer { layer in
            layer.opacity = opacity
            layer.translateBy(x: position.x, y: position.y)
            let scale = diameter / Double(SunArcMark.span)
            layer.scaleBy(x: scale, y: scale)
            layer.translateBy(x: -SunArcMark.center.x, y: -SunArcMark.center.y)
            layer.fill(SunArcMark.beamsPath(), with: .color(Color(sunArcHex: SunArc.goldHex)))
            layer.stroke(SunArcMark.ringPath(), with: .color(Color(sunArcHex: SunArc.orangeHex)), lineWidth: SunArcMark.ringLineWidth)
        }
    }
}

extension Color {
    init(sunArcHex hex: String) {
        let rgb = SunArcOKLab.rgb(fromHex: hex)
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}
