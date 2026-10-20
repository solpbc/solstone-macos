// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct SetupLevelMeter: View {
    @Environment(\.colorScheme) private var colorScheme
    private let peak: @MainActor () -> Float?
    private let paused: Bool

    @State private var history: [Float] = []

    public init(peak: @escaping @MainActor () -> Float?, paused: Bool) {
        self.peak = peak
        self.paused = paused
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            content
                .onAppear {
                    tick()
                }
                .onChange(of: Date.now) { _, _ in
                    tick()
                }
        }
    }

    @MainActor
    private func tick() {
        if !paused {
            let reading = peak()
            if let reading {
                let clamped = min(max(reading, 0.0), 1.0)
                history.append(clamped)
            } else if !history.isEmpty {
                history.append(0.0)
            }
            if history.count > 40 {
                history.removeFirst(history.count - 40)
            }
        }
    }

    private var content: some View {
        let displayBars: [Float] = {
            if history.isEmpty {
                return Array(repeating: 0.0, count: 40)
            }
            if history.count < 40 {
                return Array(repeating: 0.0, count: 40 - history.count) + history
            }
            return Array(history.suffix(40))
        }()

        let hasReading = history.contains { $0 > 0.001 }

        return HStack(alignment: .center, spacing: 3) {
            ForEach(0..<40, id: \.self) { i in
                let val = displayBars[i]
                let barHeight: CGFloat = val > 0.001 ? max(4, CGFloat(val) * 96) : 4

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(hasReading: hasReading, val: val))
                    .frame(width: 4, height: barHeight)
            }
        }
        .frame(height: 96)
    }

    private func barColor(hasReading: Bool, val: Float) -> Color {
        if paused {
            return SetupChromeColor.hairline2(for: colorScheme).opacity(0.45)
        }
        if !hasReading || val <= 0.001 {
            return SetupChromeColor.hairline2(for: colorScheme)
        }
        return SetupChromeColor.solOrange
    }
}
