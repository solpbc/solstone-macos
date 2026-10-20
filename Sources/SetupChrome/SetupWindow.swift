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
    private let windowTitle: String?
    private let background: SunArcBackgroundView
    private let content: Content

    /// `windowTitle` is the window's title while setup shows (it names the window in the Window
    /// menu and app switchers, never on screen).
    public init(
        appLabel: String,
        windowTitle: String? = nil,
        background: SunArcBackgroundView = SunArcBackgroundView(),
        @ViewBuilder content: () -> Content
    ) {
        self.appLabel = appLabel
        self.windowTitle = windowTitle
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

                    SetupBandLabel(appLabel)

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
        // The sun runs up under the window controls. A SwiftUI window scene owns its title
        // bar's transparency (its bar appearance bridge writes it back to opaque on scene
        // updates: activation, the Dock menu, ordering), so setting it on the NSWindow alone
        // does not hold. Declaring the window toolbar's background hidden makes SwiftUI keep it
        // transparent for as long as the setup window is on screen. Once SwiftUI owns the bar
        // it also writes the title and its visibility (macOS 27 writes the scene's title back
        // on screen), so the setup window declares those too: no title on screen, and its own
        // title for the Window menu and app switchers.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .modifier(SetupWindowTitle(title: windowTitle))
    }
}

private struct SetupWindowTitle: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content.navigationTitle(title)
        } else {
            content
        }
    }
}

/// The app's label in the top band: 12 pt faint ink on a chip of the sheet's own fill with
/// the sheet's hairline, so the label never sits on the sun. The lockup stays on the ground.
public struct SetupBandLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(SetupChromeColor.sheet(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(SetupChromeColor.hairline(for: colorScheme), lineWidth: 1)
            )
    }
}
