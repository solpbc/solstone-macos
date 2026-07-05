// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCore
import SwiftUI

struct JournalDevicesPane: View {
    @Bindable var model: JournalDevicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(DevicesCopy.paneTitle)
                .font(.title2.weight(.semibold))

            AXStateCompanion(id: AXID.Journal.Devices.loadState, value: model.loadState.axToken)

            switch model.loadState {
            case .loading:
                loadingContent
            case .loaded:
                loadedContent
            case .empty:
                emptyContent
            case .notRunning:
                unavailableContent(title: DevicesCopy.notRunningTitle, body: DevicesCopy.notRunningBody)
            case .notReady:
                unavailableContent(
                    title: DevicesCopy.notReadyTitle,
                    body: model.loadErrorDetail ?? DevicesCopy.notReadyBody
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Journal.Devices.root)
        .sheet(isPresented: $model.isPairingPresented, onDismiss: {
            model.closePairing()
        }) {
            JournalPairingWindow(model: model)
        }
        .sheet(item: $model.revokeCandidate) { row in
            RevokeConfirmSheet(model: model, row: row)
        }
    }

    private var loadingContent: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text(DevicesCopy.loading)
                .foregroundStyle(.secondary)
        }
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            addDeviceButton
            ForEach(model.groups) { group in
                groupView(group)
            }
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(DevicesCopy.emptyTitle)
                .font(.headline)
            Text(DevicesCopy.emptyBody)
                .foregroundStyle(.secondary)
            addDeviceButton
        }
    }

    private func unavailableContent(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button(DevicesCopy.tryAgain) {
                Task { await model.loadDevices() }
            }
        }
    }

    private var addDeviceButton: some View {
        Button {
            model.openPairing()
        } label: {
            Label(DevicesCopy.addDevice, systemImage: "plus")
        }
        .accessibilityIdentifier(AXID.Journal.Devices.addDevice)
    }

    private func groupView(_ group: JournalDeviceGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(.headline)
                    .accessibilityIdentifier(groupHeaderID(group))
                Text("\(group.count)")
                    .foregroundStyle(.secondary)
            }
            AXStateCompanion(id: groupCountStateID(group), value: String(group.count))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.rows) { row in
                    deviceRow(row)
                    if row.fingerprint != group.rows.last?.fingerprint {
                        Divider()
                    }
                }
            }
        }
    }

    private func deviceRow(_ row: DeviceRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName(for: row))
                        .font(.body.weight(.medium))
                        .accessibilityIdentifier(AXID.Journal.Devices.Row.label(row.fingerprint))
                    if let subtitle = model.subtitle(for: row) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(DevicesCopy.remove) {
                    model.beginRevoke(row)
                }
                .disabled(model.isRenaming(row))
                .accessibilityIdentifier(AXID.Journal.Devices.Row.revoke(row.fingerprint))
            }

            HStack(spacing: 8) {
                TextField(
                    DevicesCopy.renamePlaceholder,
                    text: Binding(
                        get: { model.draftLabel(for: row) },
                        set: { model.setDraftLabel($0, for: row) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AXID.Journal.Devices.Row.renameField(row.fingerprint))
                .onSubmit {
                    Task { await model.saveRename(for: row) }
                }

                Button(DevicesCopy.renameSave) {
                    Task { await model.saveRename(for: row) }
                }
                .disabled(model.isRenaming(row))
                .accessibilityIdentifier(AXID.Journal.Devices.Row.renameSave(row.fingerprint))
            }

            if let error = model.renameErrors[row.fingerprint] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            AXStateCompanion(
                id: AXID.Journal.Devices.Row.renameErrorState(row.fingerprint),
                value: model.renameErrors[row.fingerprint] ?? ""
            )
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Journal.Devices.Row.container(row.fingerprint))
    }

    private func groupHeaderID(_ group: JournalDeviceGroup) -> String {
        group.id == "peerJournals"
            ? AXID.Journal.Devices.peerJournalsHeader
            : AXID.Journal.Devices.yourDevicesHeader
    }

    private func groupCountStateID(_ group: JournalDeviceGroup) -> String {
        group.id == "peerJournals"
            ? AXID.Journal.Devices.peerJournalsCountState
            : AXID.Journal.Devices.yourDevicesCountState
    }
}

private struct RevokeConfirmSheet: View {
    @Bindable var model: JournalDevicesModel
    let row: DeviceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(DevicesCopy.revokeTitle(model.displayName(for: row)))
                .font(.title3.weight(.semibold))
            let message = DevicesCopy.revokeBody(model.displayName(for: row))
            Text(message)
                .foregroundStyle(.secondary)
            AXStateCompanion(id: AXID.Journal.Devices.RevokeConfirm.messageState, value: message)

            if let error = model.revokeError {
                Text(error)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(DevicesCopy.cancel) {
                    model.cancelRevoke()
                }
                .disabled(model.isRevoking(row))
                .accessibilityIdentifier(AXID.Journal.Devices.RevokeConfirm.cancel)

                Spacer()

                Button(DevicesCopy.remove) {
                    Task { await model.confirmRevoke() }
                }
                .disabled(model.isRevoking(row))
                .accessibilityIdentifier(AXID.Journal.Devices.RevokeConfirm.confirm)
            }
        }
        .padding(24)
        .frame(width: 380)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Journal.Devices.RevokeConfirm.dialog)
        .interactiveDismissDisabled(model.isRevoking(row))
    }
}
