// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// About window showing app identity, version, and copyright
struct AboutView: View {
    enum CopyState: Equatable {
        case copied
        case failed
    }

    let aboutBlock: () -> String
    let clipboardWrite: (String) -> Bool
    @State private var copyState: CopyState?

    init(aboutBlock: @escaping () -> String, clipboardWrite: @escaping (String) -> Bool) {
        self.aboutBlock = aboutBlock
        self.clipboardWrite = clipboardWrite
    }

    var body: some View {
        let displayedBlock = aboutBlock()
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                bundleImage("AppIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .accessibilityIdentifier(AXID.About.logo)

                Text("solstone")
                    .font(.title)
                    .fontWeight(.bold)
                    .accessibilityIdentifier(AXID.About.title)
            }

            Spacer().frame(height: 16)

            VStack(spacing: 6) {
                Text(displayedBlock)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(AXID.About.aboutState)
                    .accessibilityValue(displayedBlock)

                Button("copy") {
                    let snapshot = aboutBlock()
                    copyState = clipboardWrite(snapshot) ? .copied : .failed
                }
                .accessibilityIdentifier(AXID.About.aboutCopy)
                if let copyState {
                    Text(copyState == .copied ? "copied" : "couldn't copy. select the text and copy it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.About.aboutCopyFeedback)
                }

                Text("by sol pbc")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("open source, local-first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("a public benefit corporation. your data is never sold or shared, by binding legal covenant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 12)

            Text("the solstone app takes in what you share with it, and all of it goes into your journal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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
