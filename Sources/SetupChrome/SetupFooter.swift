// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct SetupFooter<Back: View, Progress: View, Downloads: View, Primary: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let back: Back
    private let progress: Progress
    private let downloads: Downloads
    private let primary: Primary

    public init(
        @ViewBuilder back: () -> Back = { EmptyView() },
        @ViewBuilder progress: () -> Progress = { EmptyView() },
        @ViewBuilder downloads: () -> Downloads = { EmptyView() },
        @ViewBuilder primary: () -> Primary = { EmptyView() }
    ) {
        self.back = back()
        self.progress = progress()
        self.downloads = downloads()
        self.primary = primary()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SetupChromeColor.hairline(for: colorScheme))
                .frame(height: 1)

            HStack(spacing: 16) {
                back
                progress
                Spacer()
                downloads
                primary
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
            .frame(minHeight: 66)
            .background(SetupChromeColor.footer(for: colorScheme))
        }
    }
}

extension SetupFooter where Back == EmptyView, Progress == EmptyView, Downloads == EmptyView, Primary == EmptyView {
    public init() {
        self.init(
            back: { EmptyView() },
            progress: { EmptyView() },
            downloads: { EmptyView() },
            primary: { EmptyView() }
        )
    }
}
