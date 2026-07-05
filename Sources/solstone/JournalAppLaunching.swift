// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit

@MainActor
protocol JournalAppLaunching {
    func launchOrDownload()
}

@MainActor
protocol JournalAppWorkspace {
    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL?
    func openApplication(at appURL: URL)
    func open(_ url: URL)
}

@MainActor
struct NSWorkspaceJournalAppWorkspace: JournalAppWorkspace {
    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func openApplication(at appURL: URL) {
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
struct LiveJournalAppLauncher: JournalAppLaunching {
    private let workspace: any JournalAppWorkspace

    init(workspace: any JournalAppWorkspace = NSWorkspaceJournalAppWorkspace()) {
        self.workspace = workspace
    }

    func launchOrDownload() {
        if let appURL = workspace.urlForApplication(withBundleIdentifier: "app.solstone.journal") {
            workspace.openApplication(at: appURL)
            return
        }

        if let downloadURL = URL(string: "https://solstone.app/download") {
            workspace.open(downloadURL)
        }
    }
}
