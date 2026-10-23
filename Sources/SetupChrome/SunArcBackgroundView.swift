// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The sun, all day — the mark as this window's time-of-day background. One sun per surface
/// (§8); drawn behind all window content, never reacted to. `TimelineView(.everyMinute)`
/// recomputes position at most once a minute (§9) — the pattern has no continuous animation.
///
/// Appearance (2026-09-23): the owner's own light/dark setting picks the ground, read from
/// `@Environment(\.colorScheme)`, which follows the window's effective appearance and so the
/// system setting, live. The pattern never sets the appearance — no `.preferredColorScheme`,
/// no `NSApp.appearance`, nothing by clock.
///
/// Location: this app holds no location authorization anywhere, for any purpose, and ⛔ never
/// asks for one for this pattern alone. Sunrise and sunset come from `SunArcSolar.pair(for:)`
/// — the system timezone's bundled tzdb reference point (§5 rung 2), falling to 06:30/19:30
/// only for a zone identifier the table does not know (rung 3). Both the zone and the clock
/// read `autoupdatingCurrent`, so a timezone change lands on the next minute tick without an
/// observer.
public struct SunArcBackgroundView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var nightCache = NightSkyCache()
    @State private var visible = true

    /// Test seams for the snapshot matrix: a fixed instant and zone. Production passes neither
    /// and draws the `TimelineView`'s own minute in the system's autoupdating zone.
    private let fixedDate: Date?
    private let timeZone: TimeZone

    public init(fixedDate: Date? = nil, timeZone: TimeZone = .autoupdatingCurrent) {
        self.fixedDate = fixedDate
        self.timeZone = timeZone
    }

    public var body: some View {
        let appearance: SunArcAppearance = colorScheme == .dark ? .dark : .light
        TimelineView(NightMinuteSchedule(visible: visible)) { context in
            GeometryReader { proxy in
                let date = fixedDate ?? context.date
                let solar = SunArcSolar.pair(for: date, timeZone: timeZone)
                let f = Self.frame(size: proxy.size, date: date, appearance: appearance, timeZone: timeZone)
                ZStack {
                    Canvas { ctx, size in
                        Self.draw(in: &ctx, size: size, date: date, appearance: appearance, timeZone: timeZone, sunOnly: false)
                    }
                    NightSkyView(cache: nightCache, size: proxy.size,
                        frame: NightFrame(t: f.time.t, night: f.time.night, weight: f.twilight.w,
                            glows: [f.halo,f.twilightGlow].compactMap{$0}.map{NightGlow(x:$0.center.x,y:$0.center.y,radius:$0.radius,alpha:$0.alpha)}),
                        rise: solar.riseMinutes, set: solar.setMinutes,
                        minute: Self.minutesSinceMidnight(date,timeZone:timeZone),
                        dark: appearance == .dark, watch: false, visible: visible, sampledMinute: fixedDate.map{Self.minutesSinceMidnight($0,timeZone:timeZone)}, sampledAt: date)
                    Canvas { ctx,size in
                        Self.draw(in: &ctx,size:size,date:date,appearance:appearance,timeZone:timeZone,sunOnly:true)
                    }
                }
            }
        }
        .background(NightWindowVisibility(visible: $visible))
        .allowsHitTesting(false)
    }

    static func minutesSinceMidnight(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0)) + Double(comps.second ?? 0)/60 + Double(comps.nanosecond ?? 0)/60_000_000_000
    }

    static func frame(size: CGSize, date: Date, appearance: SunArcAppearance, timeZone: TimeZone = .autoupdatingCurrent) -> SunArcFrame {
        let solar = SunArcSolar.pair(for: date, timeZone: timeZone)
        return SunArcFrame.compute(
            size: size,
            minutes: minutesSinceMidnight(date, timeZone: timeZone),
            riseMinutes: solar.riseMinutes,
            setMinutes: solar.setMinutes,
            appearance: appearance
        )
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, date: Date, appearance: SunArcAppearance, timeZone: TimeZone = .autoupdatingCurrent, sunOnly: Bool? = nil) {
        guard size.width > 0, size.height > 0 else { return }
        let frame = frame(size: size, date: date, appearance: appearance, timeZone: timeZone)

        if sunOnly != true {
        // ground — behind everything (§6)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(sunArcHex: frame.groundHex)))

        // the day halo, then the twilight glow — under the sun, over the ground (§7)
        for glow in [frame.halo, frame.twilightGlow].compactMap({ $0 }) where glow.alpha > 0.002 {
            let color = Color(sunArcHex: glow.colorHex)
            let gradient = Gradient(stops: [
                .init(color: color.opacity(glow.alpha), location: 0),
                .init(color: color.opacity(glow.alpha * SunArc.gradientMidRatio), location: SunArc.gradientMidStop),
                .init(color: color.opacity(0), location: 1)
            ])
            let r = glow.radius
            ctx.fill(
                Path(ellipseIn: CGRect(x: glow.center.x - r, y: glow.center.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(gradient, center: glow.center, startRadius: 0, endRadius: r)
            )
        }

        }
        if sunOnly == false {return}
        // the sun — one graphic (§8), never redrawn: the mark, scaled and translated (§10)
        guard frame.sunVisible, frame.sunOpacity > 0.001 else { return }
        ctx.drawLayer { layer in
            layer.opacity = frame.sunOpacity
            layer.translateBy(x: frame.sunCenter.x, y: frame.sunCenter.y)
            let scale = frame.sunDiameter / Double(SunArcMark.span)
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
