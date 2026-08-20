// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

internal struct SRGBAColorComponents: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

internal enum SolstoneColors {
    // Canonical source: Sources/solstone/Resources/Assets.xcassets/AccentColor.colorset
    // solOrange #E8913A is the mark accent; #B06A1A is text/link/focus ink only.
    static let solOrangeComponents = SRGBAColorComponents(
        red: 232.0 / 255.0,
        green: 145.0 / 255.0,
        blue: 58.0 / 255.0,
        alpha: 1.0
    )

    static let solOrange = Color(
        .sRGB,
        red: solOrangeComponents.red,
        green: solOrangeComponents.green,
        blue: solOrangeComponents.blue,
        opacity: solOrangeComponents.alpha
    )
}
