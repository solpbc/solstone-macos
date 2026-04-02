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
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                bundleImage("sol-wordmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)

                Text("solstone")
                    .font(.title)
                    .fontWeight(.bold)
            }

            Spacer().frame(height: 16)

            VStack(spacing: 4) {
                Text("version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("by sol pbc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 12)

            Text("an AI co-brain that captures your life and gives you superhuman memory.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Link("solpbc.org", destination: URL(string: "https://solpbc.org")!)
                .font(.callout)
        }
        .padding(30)
    }
}
