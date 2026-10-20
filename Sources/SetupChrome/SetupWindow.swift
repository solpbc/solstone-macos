// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI

/// SwiftPM's generated `Bundle.module` stops the process when the resource bundle is not
/// where it expects, so the lockup looks for the bundle itself: inside the app's
/// Resources (how the apps package it), beside the executable, then at the build path
/// tests use. A missing bundle drops the lockup; it never stops setup.
private let setupChromeResources: Bundle? = {
    let name = "solstone_SetupChrome.bundle"
    var candidates: [URL] = []
    if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(name)) }
    candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
    if let executable = Bundle.main.executableURL {
        candidates.append(executable.deletingLastPathComponent().appendingPathComponent(name))
    }
    for bundle in Bundle.allBundles + Bundle.allFrameworks {
        candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name))
    }
    for url in candidates {
        if let bundle = Bundle(url: url) { return bundle }
    }
    return nil
}()

private let lockupImage: NSImage? = {
    guard let bundle = setupChromeResources else { return nil }
    let url = bundle.url(forResource: "lockup-solstone-horizontal", withExtension: "pdf", subdirectory: "Resources")
        ?? bundle.url(forResource: "lockup-solstone-horizontal", withExtension: "pdf")
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

                // Sheet directly under the band. The content is wrapped first so the sheet is
                // one panel even when the caller passes several views (modifiers on a group
                // apply to each child).
                ZStack(alignment: .topLeading) {
                    content
                }
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
