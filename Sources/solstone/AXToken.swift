// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
//
// Accessibility identifiers and tokens are sourced from AXID.swift and this file.
// ax-contract.json is generated from those Swift sources with `make ax-contract`,
// and `make ci` gates drift. Consumers must import the generated contract instead
// of hardcoding identifiers or token lists.

import SwiftUI

internal enum AXPermissionState: CaseIterable {
    case granted
    case denied
    case waiting
}

internal enum MenubarIconState: CaseIterable {
    case recording
    case offline
    case paused
    case error

    var iconName: String {
        switch self {
        case .recording:
            return "sol-ring-template"
        case .offline:
            return "sol-ring-icon-half-template"
        case .paused:
            return "sol-ring-icon-paused-template"
        case .error:
            return "sol-ring-icon-error-template"
        }
    }
}

internal enum MenubarStatusRowState: CaseIterable {
    case permissions
    case error
    case journalStopped
    case journalRestarting
    case journalSetupNeeded
    case journalUnknown
    case journalWaiting
    case localOnly
    case offline
    case paused
    case observing
    case stopped
}

internal enum SettingsObservationAXState: CaseIterable {
    case observing
    case paused
    case stopped

    init(isRecording: Bool, isPaused: Bool) {
        if isRecording {
            self = isPaused ? .paused : .observing
        } else {
            self = .stopped
        }
    }
}

internal enum DoctorProgress: CaseIterable {
    case running
    case done
    case error
}

struct AXStateCompanion: View {
    let id: String
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .clipped()
            .accessibilityIdentifier(id)
            .accessibilityLabel(id)
            .accessibilityValue(value)
    }
}

extension RowStatus {
    static let axTokens = [
        "pending",
        "running",
        "ok",
        "failed"
    ]

    var axToken: String {
        switch self {
        case .pending:
            return "pending"
        case .running:
            return "running"
        case .ok:
            return "ok"
        case .failed:
            return "failed"
        }
    }
}

extension InstallerCardState {
    static let axTokens = [
        "detecting",
        "absent",
        "installing",
        "installed_placeholder",
        "done",
        "installed_current",
        "installed_unknown",
        "externally_managed",
        "upgrade_failed",
        "failed"
    ]

    var axToken: String {
        switch self {
        case .detecting:
            return "detecting"
        case .absent:
            return "absent"
        case .installing:
            return "installing"
        case .installedPlaceholder:
            return "installed_placeholder"
        case .done:
            return "done"
        case .installedCurrent:
            return "installed_current"
        case .installedUnknown:
            return "installed_unknown"
        case .externallyManaged:
            return "externally_managed"
        case .upgradeFailed:
            return "upgrade_failed"
        case .failed:
            return "failed"
        }
    }
}

extension AutoTestState {
    public static let axTokens = [
        "verifying",
        "success",
        "failure"
    ]

    var axToken: String {
        switch self {
        case .verifying:
            return "verifying"
        case .success:
            return "success"
        case .failure:
            return "failure"
        }
    }
}

extension DoctorStatus {
    static let axTokens = [
        "ok",
        "warn",
        "fail",
        "skip",
        "unknown"
    ]

    var axToken: String {
        switch self {
        case .ok:
            return "ok"
        case .warn:
            return "warn"
        case .fail:
            return "fail"
        case .skip:
            return "skip"
        case .unknown:
            return "unknown"
        }
    }
}

extension UploadCoordinator.Status {
    public static let axTokens = [
        "not_synced",
        "syncing",
        "synced",
        "uploading",
        "retrying",
        "offline"
    ]

    var axToken: String {
        switch self {
        case .notSynced:
            return "not_synced"
        case .syncing:
            return "syncing"
        case .synced:
            return "synced"
        case .uploading:
            return "uploading"
        case .retrying:
            return "retrying"
        case .offline:
            return "offline"
        }
    }
}

extension ConnectionTestState {
    public static let axTokens = [
        "idle",
        "testing",
        "success",
        "failure"
    ]

    var axToken: String {
        switch self {
        case .idle:
            return "idle"
        case .testing:
            return "testing"
        case .success:
            return "success"
        case .failure:
            return "failure"
        }
    }
}

extension UpdateActivity {
    static let axTokens = [
        "idle",
        "checking",
        "downloading",
        "extracting",
        "ready_to_install",
        "installing"
    ]

    var axToken: String {
        switch self {
        case .idle:
            return "idle"
        case .checking:
            return "checking"
        case .downloading:
            return "downloading"
        case .extracting:
            return "extracting"
        case .readyToInstall:
            return "ready_to_install"
        case .installing:
            return "installing"
        }
    }
}

extension JournalRuntimeStatus {
    static let axTokens = [
        "running",
        "journal_restarting",
        "journal_setup_needed",
        "journal_stopped",
        "journal_unknown"
    ]
}

enum UpdateStatus {
    static let axTokens = UpdateActivity.axTokens + [
        "deferred_install",
        "update_available",
        "up_to_date",
        "error"
    ]
}

extension AXPermissionState {
    var axToken: String {
        switch self {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .waiting:
            return "waiting"
        }
    }
}

extension MenubarIconState {
    var axToken: String {
        switch self {
        case .recording:
            return "recording"
        case .offline:
            return "offline"
        case .paused:
            return "paused"
        case .error:
            return "error"
        }
    }
}

extension MenubarStatusRowState {
    var axToken: String {
        switch self {
        case .permissions:
            return "permissions"
        case .error:
            return "error"
        case .journalStopped:
            return "journal_stopped"
        case .journalRestarting:
            return "journal_restarting"
        case .journalSetupNeeded:
            return "journal_setup_needed"
        case .journalUnknown:
            return "journal_unknown"
        case .journalWaiting:
            return "journal_waiting"
        case .localOnly:
            return "local_only"
        case .offline:
            return "offline"
        case .paused:
            return "paused"
        case .observing:
            return "observing"
        case .stopped:
            return "stopped"
        }
    }
}

extension SettingsObservationAXState {
    var axToken: String {
        switch self {
        case .observing:
            return "observing"
        case .paused:
            return "paused"
        case .stopped:
            return "stopped"
        }
    }
}

extension SettingsView.SidebarBadgeState {
    var axToken: String {
        switch self {
        case .attention:
            return "attention"
        case .done:
            return "done"
        case .blank:
            return "none"
        }
    }
}

extension DoctorProgress {
    var axToken: String {
        switch self {
        case .running:
            return "running"
        case .done:
            return "done"
        case .error:
            return "error"
        }
    }
}

func doctorProgressAXToken(for result: JournalDoctorResult?) -> String {
    switch result {
    case nil:
        return DoctorProgress.running.axToken
    case .report:
        return DoctorProgress.done.axToken
    case .setupNeeded, .stopped, .unknown:
        return DoctorProgress.error.axToken
    }
}

func axIntegerString(_ value: Int) -> String {
    String(value)
}

func axPercentString(_ fraction: Double) -> String {
    let percent = Int((fraction * 100).rounded())
    return String(min(max(percent, 0), 100))
}

func axDownloadPercentString(receivedBytes: UInt64, totalBytes: UInt64?) -> String {
    guard let totalBytes, totalBytes > 0 else { return "0" }
    return axPercentString(Double(receivedBytes) / Double(totalBytes))
}

func axModelDownloadPercentString(_ progress: ModelsProgress) -> String {
    switch progress {
    case .idle:
        return "0"
    case .running(let subprocessProgress):
        guard let stepIndex = subprocessProgress.stepIndex,
              let stepTotal = subprocessProgress.stepTotal,
              stepTotal > 0 else {
            return "0"
        }
        return axPercentString(Double(stepIndex) / Double(stepTotal))
    case .done:
        return "100"
    case .failed:
        return "0"
    }
}
