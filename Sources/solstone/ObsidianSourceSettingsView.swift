// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SolstoneCore
import SwiftUI

/// The Obsidian source in Settings, beside the other sources.
struct ObsidianSourceSettingsView: View {
    let source: ObsidianVaultSource
    /// On a source page the verdict above already names the source and its state.
    var onSourcePage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !onSourcePage {
                Text(UICopy.Obsidian.TITLE)
                    .font(.headline)
            }
            AXStateCompanion(id: AXID.Settings.Sources.obsidianState, value: source.axState.axToken)

            if let warning = source.alreadySynced {
                alreadySyncedSection(warning)
            } else if source.isOn {
                statusSection
            } else {
                offSection
            }

            if let refusal = source.refusal {
                Text(refusalText(refusal))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Settings.Sources.obsidianRefusal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .task { source.refreshFoundVaults() }
    }

    private var offSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !onSourcePage {
                Text(UICopy.Obsidian.EXPLAINER)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !source.foundVaults.isEmpty {
                Text(UICopy.Obsidian.FOUND_VAULTS)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(source.foundVaults) { vault in
                    Button(vault.name) {
                        Task { await source.turnOn(vault.url) }
                    }
                    .accessibilityIdentifier(AXID.Settings.Sources.obsidianFoundVault)
                }
            }

            Button(UICopy.Obsidian.CHOOSE_FOLDER) { chooseFolder() }
                .accessibilityIdentifier(AXID.Settings.Sources.obsidianChooseFolder)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !onSourcePage {
                Text(UICopy.Obsidian.stateLine(source.phase, vaultName: source.snapshot.state.vaultName))
                    .accessibilityIdentifier(AXID.Settings.Sources.obsidianStatus)
            }

            if source.phase == .needsAttention, !onSourcePage {
                Text(UICopy.Obsidian.attentionLine(vaultUnreadable: source.snapshot.vaultUnreadable, partUnreadable: source.snapshot.partUnreadable))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Settings.Sources.obsidianAttention)
            }

            if let lastChecked = source.snapshot.lastCheckedMs {
                let date = Date(timeIntervalSince1970: TimeInterval(lastChecked) / 1000)
                Text(UICopy.Obsidian.lastChecked(date.formatted(date: .omitted, time: .shortened)))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Settings.Sources.obsidianLastChecked)
            }

            Text(UICopy.Obsidian.waiting(source.snapshot.waiting))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AXID.Settings.Sources.obsidianWaiting)

            if let total = source.snapshot.state.firstSyncTotal {
                Text(UICopy.Obsidian.progress(sent: min(source.snapshot.state.firstSyncDelivered, total), found: total))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Settings.Sources.obsidianProgress)
            }

            if source.snapshot.notOnDevice > 0 {
                Text(UICopy.Obsidian.notOnThisMac(source.snapshot.notOnDevice))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Settings.Sources.obsidianNotOnDevice)
            }

            if source.snapshot.tooLarge > 0 {
                Text(UICopy.Obsidian.tooLarge(source.snapshot.tooLarge))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Settings.Sources.obsidianTooLarge)
            }

            Button(UICopy.Obsidian.TURN_OFF) {
                Task { await source.turnOff() }
            }
            .accessibilityIdentifier(AXID.Settings.Sources.obsidianTurnOff)

            Text(UICopy.Obsidian.TURN_OFF_HELP)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func alreadySyncedSection(_ warning: ObsidianVaultSource.AlreadySynced) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UICopy.Obsidian.alreadySynced(vault: warning.vault, device: warning.device, date: lastSyncedDate(warning.lastSyncedAt)))
                .accessibilityIdentifier(AXID.Settings.Sources.obsidianAlreadySynced)
            HStack {
                Button(UICopy.Obsidian.CONTINUE) {
                    Task { await source.continueAfterAlreadySynced() }
                }
                .accessibilityIdentifier(AXID.Settings.Sources.obsidianContinue)
                Button(UICopy.Obsidian.CANCEL) {
                    Task { await source.cancelAfterAlreadySynced() }
                }
                .accessibilityIdentifier(AXID.Settings.Sources.obsidianCancel)
            }
        }
    }

    private func refusalText(_ refusal: ObsidianVaultSource.Refusal) -> String {
        switch refusal {
        case .notAVault: return UICopy.Obsidian.REFUSED_NOT_A_VAULT
        case .unreadable: return UICopy.Obsidian.REFUSED_UNREADABLE
        case .unusableName: return UICopy.Obsidian.REFUSED_UNUSABLE_NAME
        }
    }

    private func lastSyncedDate(_ value: String?) -> String? {
        guard let value else { return nil }
        guard let date = try? Date(value, strategy: .iso8601) else { return value }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = UICopy.Obsidian.PANEL_PROMPT
        panel.message = UICopy.Obsidian.PANEL_MESSAGE
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await source.turnOn(url) }
    }
}
