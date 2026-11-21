// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SetupChrome
import SwiftUI

extension SharedSourceDetail {
    private var stateWords: String? {
        switch state {
        case "paused": return DeckStateWord.paused.word
        case "needs_attention": return DeckStateWord.needsAttention.word
        default: return nil
        }
    }

    func line(at now: Date) -> String? {
        let relative = time.map { relativeWords($0, now: now) }
        switch (detail, stateWords, relative) {
        case let (detail?, state?, time?): return MacStrings.macos_shared_sa4(detail, state, time)
        case let (detail?, nil, time?): return MacStrings.macos_shared_sa4time(detail, time)
        case let (detail?, state?, nil): return MacStrings.macos_shared_sa4state(detail, state)
        case let (nil, state?, time?): return MacStrings.macos_shared_sa4statetime(state, time)
        default: return detail ?? stateWords ?? relative
        }
    }

    func summary(device: String, at now: Date) -> String {
        switch (stateWords, time.map { relativeWords($0, now: now) }) {
        case let (state?, time?): return MacStrings.macos_shared_sa3(device, state, time)
        case let (state?, nil): return MacStrings.macos_shared_sa3state(device, state)
        case let (nil, time?): return MacStrings.macos_shared_sa3time(device, time)
        default: return device
        }
    }
}

extension SharedSourceDevice {
    func summary(at now: Date) -> String { rows.first?.summary(device: name, at: now) ?? name }

    var glyph: String {
        switch type {
        case "phone", "mobile": return "smartphone"
        case "tablet": return "ipad"
        case "laptop": return "laptopcomputer"
        case "desktop": return "desktopcomputer"
        default: return "rectangle"
        }
    }
}

struct SharedSourceHeading: View {
    let count: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            Circle().strokeBorder(lineWidth: 1.2)
                .overlay { Circle().frame(width: 3, height: 3) }
                .frame(width: 8, height: 8).accessibilityHidden(true)
            Text(MacStrings.macos_shared_sa12(count))
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(SetupChromeColor.softInk(for: scheme))
    }
}

struct SharedSourceCard: View {
    let devices: [SharedSourceDevice]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 10) {
                SharedSourceHeading(count: devices.count)
                ForEach(devices) { device in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: device.glyph).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                            ForEach(device.rows.indices, id: \.self) { index in
                                if let line = device.rows[index].line(at: context.date) {
                                    Text(line).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(SetupChromeColor.card(for: scheme)))
        }
    }
}
