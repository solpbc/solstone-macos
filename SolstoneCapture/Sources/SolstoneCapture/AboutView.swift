// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// About window showing app identity, version, and copyright
struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 12) {
            bundleImage("sol-wordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            Text("solstone")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("by sol pbc")
                .font(.callout)

            Text("an AI co-brain that captures your life and gives you superhuman memory.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(copyright)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Link("solpbc.org", destination: URL(string: "https://solpbc.org")!)
                .font(.callout)
        }
        .padding(30)
    }
}
