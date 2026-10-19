// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI

private let lockupImage: NSImage? = {
    let url = Bundle.module.url(forResource: "lockup-solstone-horizontal", withExtension: "pdf", subdirectory: "Resources")
        ?? Bundle.module.url(forResource: "lockup-solstone-horizontal", withExtension: "pdf")
    guard let url else { return nil }
    return NSImage(contentsOf: url)
}()

public struct SetupWindow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let appLabel: String
    private let background: SunArcBackgroundView
    private let content: Content

    public init(
        appLabel: String,
        background: SunArcBackgroundView = SunArcBackgroundView(),
        @ViewBuilder content: () -> Content
    ) {
        self.appLabel = appLabel
        self.background = background
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top band ~56 pt
                HStack(spacing: 0) {
                    if let image = lockupImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 26)
                    }

                    Spacer().frame(width: 12)

                    Rectangle()
                        .fill(SetupChromeColor.hairline(for: colorScheme))
                        .frame(width: 1, height: 16)

                    Spacer().frame(width: 12)

                    Text(appLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))

                    Spacer()
                }
                .padding(.leading, 40)
                .frame(height: 56)

                // Sheet directly under the band
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(SetupChromeColor.sheet(for: colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(SetupChromeColor.hairline(for: colorScheme), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding([.leading, .trailing, .bottom], 18)
            }
        }
    }
}
