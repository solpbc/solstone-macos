// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCore
import SwiftUI

/// The solstone mark's geometry — beams + ring — vendored from
/// `cmo/projects/sol-mark-rollout/staging/sol-mark.py` in the extro repo (the parametric source;
/// locked 2026-08-19). Ten inward-bowed beams at 36°, a ring at r=6.5. This is the mark used as
/// the sun-arc background's one graphic — NOT the journal identity mark (`JournalMarkKit`),
/// which is the two-chip owner mark and a different construction entirely.
enum SunArcMark {
    /// Mark-space centre. viewBox is "2.5 2.5 27 27": the tips terminate on it.
    static let center = CGPoint(x: 16, y: 16)
    /// The full mark spans this many mark-units, tip to tip — the scale divisor for placement.
    static let span: CGFloat = 27

    private static let phi: Double = SunArc.phi
    private static let tipRadius: Double = 13.5
    private static let baseRadius: Double = 8.5 + 1 / phi
    private static let bow: Double = 0.27
    private static let beamCount = 10
    private static let beamStepDegrees: Double = 36
    private static let beamDegrees: Double = 33
    static let ringRadius: CGFloat = 6.5
    static let ringLineWidth: CGFloat = 2 / phi + 0.5

    private static func rotate(_ p: CGPoint, degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        let dx = Double(p.x) - Double(center.x), dy = Double(p.y) - Double(center.y)
        return CGPoint(
            x: Double(center.x) + dx * cos(a) - dy * sin(a),
            y: Double(center.y) + dx * sin(a) + dy * cos(a)
        )
    }

    /// tip, control-for-right-base, right-base, left-base, control-for-left-base — beam 0, pointing up.
    private static func beam0Anchors() -> (tip: CGPoint, controlRight: CGPoint, baseRight: CGPoint, baseLeft: CGPoint, controlLeft: CGPoint) {
        let half = beamDegrees / 2 * .pi / 180
        let tip = CGPoint(x: center.x, y: Double(center.y) - tipRadius)
        let baseRight = CGPoint(x: Double(center.x) + baseRadius * sin(half), y: Double(center.y) - baseRadius * cos(half))
        let baseLeft = CGPoint(x: Double(center.x) - baseRadius * sin(half), y: Double(center.y) - baseRadius * cos(half))

        func control(_ base: CGPoint) -> CGPoint {
            let mx = (Double(tip.x) + Double(base.x)) / 2, my = (Double(tip.y) + Double(base.y)) / 2
            let vx = Double(base.x) - Double(tip.x), vy = Double(base.y) - Double(tip.y)
            let length = (vx * vx + vy * vy).squareRoot()
            let ux = vx / length, uy = vy / length
            var px = -uy, py = ux
            if abs(mx + bow * px - Double(center.x)) > abs(mx - bow * px - Double(center.x)) {
                px = -px; py = -py
            }
            return CGPoint(x: mx + bow * px, y: my + bow * py)
        }

        return (tip, control(baseRight), baseRight, baseLeft, control(baseLeft))
    }

    private static func angle(of p: CGPoint) -> Double {
        atan2(Double(p.y) - Double(center.y), Double(p.x) - Double(center.x))
    }

    /// One beam (a kite: a bowed-quadratic tip-to-base pair, a concave base arc cutting the beam
    /// to hug the ring's air gap), rotated into slot `index` of 10.
    private static func beamPath(index: Int) -> Path {
        let deg = Double(index) * beamStepDegrees
        let anchors = beam0Anchors()
        let tip = rotate(anchors.tip, degrees: deg)
        let controlRight = rotate(anchors.controlRight, degrees: deg)
        let baseRight = rotate(anchors.baseRight, degrees: deg)
        let baseLeft = rotate(anchors.baseLeft, degrees: deg)
        let controlLeft = rotate(anchors.controlLeft, degrees: deg)

        var path = Path()
        path.move(to: tip)
        path.addQuadCurve(to: baseRight, control: controlRight)
        // the base is one arc of the circle centred on the mark's own centre (both base corners
        // sit at exactly `baseRadius` from it, by construction) — the minor (33°) arc, concave
        // toward the tip, per sol-mark.py's `A{baseRadius} {baseRadius} 0 0 0 …`. The centre is
        // invariant under rotation about itself, so it stays `center` for every beam index.
        path.addRelativeArc(
            center: center,
            radius: baseRadius,
            startAngle: Angle(radians: angle(of: baseRight)),
            delta: Angle(radians: angle(of: baseLeft) - angle(of: baseRight))
        )
        path.addQuadCurve(to: tip, control: controlLeft)
        path.closeSubpath()
        return path
    }

    /// All ten beams, one filled path (gold).
    static func beamsPath() -> Path {
        var path = Path()
        for i in 0..<beamCount {
            path.addPath(beamPath(index: i))
        }
        return path
    }

    /// The ring (stroke orange, `ringLineWidth` wide).
    static func ringPath() -> Path {
        Path(ellipseIn: CGRect(
            x: Double(center.x) - Double(ringRadius),
            y: Double(center.y) - Double(ringRadius),
            width: Double(ringRadius) * 2,
            height: Double(ringRadius) * 2
        ))
    }
}
