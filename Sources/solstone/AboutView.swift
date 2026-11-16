// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SetupChrome
import SwiftUI

/// About window showing app identity, version, and copyright
struct AboutView: View {
    enum CopyState: Equatable {
        case copied
        case failed
    }

    let renderedBlock: String
    let clipboardWrite: (String) -> Bool
    @State private var copyState: CopyState?
    @Environment(\.colorScheme) private var scheme

    init(aboutBlock: @escaping () -> String, clipboardWrite: @escaping (String) -> Bool) {
        self.renderedBlock = aboutBlock()
        self.clipboardWrite = clipboardWrite
    }

    func copyDisplayedBlock() -> Bool {
        clipboardWrite(renderedBlock)
    }

    var body: some View {
        let displayedBlock = renderedBlock
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                bundleImage("AppIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .accessibilityIdentifier(AXID.About.logo)

                Text(MacStrings.macos_about_solstone())
                    .font(.title)
                    .fontWeight(.bold)
                    .accessibilityIdentifier(AXID.About.title)
            }

            Spacer().frame(height: 16)

            VStack(spacing: 6) {
                // Centred line by line, like everything else in this window.
                Text(displayedBlock)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(AXID.About.aboutState)
                    .accessibilityValue(displayedBlock)

                Button(MacStrings.macos_desktop_shared_about_textcontent()) {
                    copyState = copyDisplayedBlock() ? .copied : .failed
                }
                .accessibilityIdentifier(AXID.About.aboutCopy)
                if let copyState {
                    Text(copyState == .copied ? MacStrings.macos_about_copied() : MacStrings.macos_desktop_shared_about_textcontent2())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.About.aboutCopyFeedback)
                }

                Text(MacStrings.macos_about_bysolpbc_mark())
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(MacStrings.macos_desktop_shared_about_opensourcelocalfirst())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(MacStrings.macos_about_apublicbenefitcorporationyourdatais())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 12)

            Text(MacStrings.macos_desktop_shared_about_setupwelcomebody1())
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            // Links take sol orange, the one accent, at the darker text shade so they read on the panel.
            VStack(spacing: 4) {
                Link(MacStrings.macos_about_sourcecodeongithub(), destination: URL(string: "https://github.com/solpbc/solstone-macos")!)
                    .font(.callout)
                    .accessibilityIdentifier(AXID.About.sourceCode)
                Link(MacStrings.macos_about_solstoneapp(), destination: URL(string: "https://solstone.app")!)
                    .font(.callout)
                    .accessibilityIdentifier(AXID.About.website)
            }
            .tint(SetupChromeColor.orangeText(for: scheme))
            .foregroundStyle(SetupChromeColor.orangeText(for: scheme))
        }
        .padding(30)
    }
}
