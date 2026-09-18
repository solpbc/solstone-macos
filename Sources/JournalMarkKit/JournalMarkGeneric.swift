// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// Visual and spoken contract for the generic mark (nil / absent / malformed / not-committed).
/// journal-mark.md section 4.3. Colors and dash geometry are the single source in
/// `JournalIconTileGeometry` (shared with the app-icon compositor) — never re-declared here,
/// so a palette fix in one place can't drift from the other.
nonisolated enum JournalMarkGeneric {
    static let words = ["your", "journal"]
    static let spokenValue = "your journal, not set up yet"
}

nonisolated enum JournalMarkAccessibility {
    static func chipToken(colorName: String?, glyphName: String) -> String {
        let tint = colorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tint.isEmpty {
            return glyphName
        }
        return "\(tint) \(glyphName)"
    }

    static func spokenValue(mark: JournalMark?) -> String {
        guard let mark, mark.words.count >= 2 else {
            return JournalMarkGeneric.spokenValue
        }
        let chip1 = Self.chipToken(colorName: mark.icon1.color.name, glyphName: mark.icon1.name)
        let chip2 = Self.chipToken(colorName: mark.icon2.color.name, glyphName: mark.icon2.name)
        return "\(chip1), \(chip2), \(mark.words[0]), \(mark.words[1])"
    }
}

/// The no-identity-yet chip: same tile, dashed border, no glyph.
/// journal-mark.md section 4.3.
struct JournalMarkGenericChip: View {
    let hex: String
    let rotated: Bool

    var body: some View {
        let color = MarkGeometry.color(hex: self.hex)
        return RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
            .fill(color.opacity(JournalIconTileGeometry.genericFillOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
                    .stroke(
                        color,
                        style: StrokeStyle(
                            lineWidth: MarkGeometry.chipBorderWidth,
                            dash: JournalIconTileGeometry.genericDashLengths(chipSide: MarkGeometry.size)
                        )
                    )
            }
            .frame(width: MarkGeometry.size, height: MarkGeometry.size)
            .rotationEffect(.degrees(self.rotated ? 45 : 0))
    }
}
