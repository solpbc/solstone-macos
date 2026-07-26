// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// About window showing app identity, version, and copyright
struct AboutView: View {
    private var version: String { AppVersion.short }

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                bundleImage("sol-wordmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .accessibilityIdentifier(AXID.About.logo)

                Text("sol")
                    .font(.title)
                    .fontWeight(.bold)
                    .accessibilityIdentifier(AXID.About.title)
            }

            Spacer().frame(height: 16)

            VStack(spacing: 4) {
                Text("version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.About.versionState)
                    .accessibilityValue(version)

                Text("by sol pbc")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("sol is part of solstone: open source, local-first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("a public benefit corporation. your data is never sold or shared, by binding legal covenant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 12)

            Text("a memory your agents can work from. always private, only yours.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: 4) {
                Link("source code on github", destination: URL(string: "https://github.com/solpbc/solstone-macos")!)
                    .font(.callout)
                    .accessibilityIdentifier(AXID.About.sourceCode)
                Link("solstone.app", destination: URL(string: "https://solstone.app")!)
                    .font(.callout)
                    .accessibilityIdentifier(AXID.About.website)
            }
        }
        .padding(30)
    }
}
