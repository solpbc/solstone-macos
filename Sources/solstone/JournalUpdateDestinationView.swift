// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import SolstoneCore
import SwiftUI
import UpdateKit

@MainActor
func verifyLocalJournalForUpdate(
    expected: TunnelPairingIdentity?,
    currentPairing: () -> TunnelPairingIdentity?,
    fetchIdentity: (String) async -> Bool
) async -> Bool {
    guard let expected else { return false }
    let matches = await fetchIdentity(expected.instanceID)
    return matches && !Task.isCancelled && currentPairing() == expected
}

struct JournalUpdateDestinationView: View {
    @Bindable var owner: TunnelLifecycleOwner
    @State private var verifiedLocalPairing: TunnelPairingIdentity?
    @State private var isOpening = false
    @State private var launchError: String?

    private let helpURL = URL(string: "https://solstone.app/install#updating")!
    private var canOpenLocalApp: Bool {
        owner.cachedPairingIdentity != nil
            && verifiedLocalPairing == owner.cachedPairingIdentity
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.solstone.journal") != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MacStrings.macos_updates_pairedjournal("\(owner.journalVersion.displayValue)"))
                .font(.headline)
                .accessibilityIdentifier(UpdatesAXID.pairedJournalVersion)
            Text(MacStrings.macos_updates_solstoneandyourjournalupdateseparatelytheir())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if canOpenLocalApp {
                Button(isOpening ? MacStrings.macos_journalupdatedestinationview_openingjournal() : MacStrings.macos_journalupdatedestinationview_openjournalapp()) {
                    Task { await openJournalApp() }
                }
                .disabled(isOpening)
                Text(MacStrings.macos_updates_chooseupdatesinthejournalapps())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(MacStrings.macos_updates_updateyourjournalonthecomputerthat())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.secondary)
            }
            Link(MacStrings.macos_updates_journalupdatehelp(), destination: helpURL)
        }
        .task(id: owner.cachedPairingIdentity) {
            launchError = nil
            verifiedLocalPairing = nil
            let expected = owner.cachedPairingIdentity
            if await verify(expected) { verifiedLocalPairing = expected }
        }
    }

    private func verify(_ expected: TunnelPairingIdentity?) async -> Bool {
        await verifyLocalJournalForUpdate(
            expected: expected,
            currentPairing: { owner.cachedPairingIdentity },
            fetchIdentity: { instanceID in
                if case .mark = await OwnJournalAccess.resolveIdentity(expectedInstanceID: instanceID) {
                    return true
                }
                return false
            }
        )
    }

    private func openJournalApp() async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let expected = owner.cachedPairingIdentity
        guard await verify(expected),
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.solstone.journal") else {
            verifiedLocalPairing = nil
            launchError = MacStrings.macos_updates_launcherror()
            return
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: application, configuration: .init())
        } catch {
            launchError = MacStrings.macos_updates_launcherror2()
        }
    }
}
