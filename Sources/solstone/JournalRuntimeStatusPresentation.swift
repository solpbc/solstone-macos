import SwiftUI

internal struct JournalRuntimeMenuRowPresentation: Equatable, Sendable {
    let text: String
    let isEnabled: Bool
    let state: MenubarStatusRowState
}

internal struct JournalRuntimeSettingsPresentation: Equatable, Sendable {
    let shortText: String
    let axValue: String
    let severity: JournalRuntimeStatusSeverity
    let reason: String?
}

internal enum JournalRuntimeStatusSeverity: Equatable, Sendable {
    case neutral
    case warning
    case attention

    var color: Color {
        switch self {
        case .neutral:
            return .secondary
        case .warning:
            return .orange
        case .attention:
            return .red
        }
    }
}

extension JournalRuntimeStatus {
    var canOfferRestart: Bool {
        switch self {
        case .stopped, .unknown:
            return true
        case .unobserved, .running, .stoppedByUser, .restarting, .setupNeeded:
            return false
        }
    }

    var menuRowPresentation: JournalRuntimeMenuRowPresentation? {
        switch self {
        case .unobserved, .running:
            return nil
        case .stoppedByUser:
            return JournalRuntimeMenuRowPresentation(
                text: UICopy.MENUBAR_JOURNAL_STOPPED_BY_USER,
                isEnabled: true,
                state: .journalStoppedByUser
            )
        case .setupNeeded:
            return JournalRuntimeMenuRowPresentation(
                text: UICopy.JOURNAL_SETUP_NEEDED_OPEN_SETTINGS,
                isEnabled: true,
                state: .journalSetupNeeded
            )
        case .restarting:
            return JournalRuntimeMenuRowPresentation(
                text: UICopy.JOURNAL_RESTARTING,
                isEnabled: false,
                state: .journalRestarting
            )
        case .stopped:
            return JournalRuntimeMenuRowPresentation(
                text: UICopy.JOURNAL_NEEDS_ATTENTION_OPEN_SETTINGS,
                isEnabled: true,
                state: .journalStopped
            )
        case .unknown:
            return JournalRuntimeMenuRowPresentation(
                text: UICopy.JOURNAL_NEEDS_ATTENTION_OPEN_SETTINGS,
                isEnabled: true,
                state: .journalUnknown
            )
        }
    }

    var settingsPresentation: JournalRuntimeSettingsPresentation {
        switch self {
        case .unobserved:
            return JournalRuntimeSettingsPresentation(
                shortText: UICopy.SETTINGS_OBSERVATION_STARTING,
                axValue: MenubarStatusRowState.starting.axToken,
                severity: .neutral,
                reason: nil
            )
        case .running:
            return JournalRuntimeSettingsPresentation(
                shortText: UICopy.JOURNAL_STATUS_RUNNING,
                axValue: "running",
                severity: .neutral,
                reason: nil
            )
        case .stoppedByUser:
            return JournalRuntimeSettingsPresentation(
                shortText: UICopy.JOURNAL_STATUS_STOPPED,
                axValue: MenubarStatusRowState.journalStoppedByUser.axToken,
                severity: .neutral,
                reason: nil
            )
        case .restarting:
            return JournalRuntimeSettingsPresentation(
                shortText: UICopy.JOURNAL_STATUS_RESTARTING,
                axValue: MenubarStatusRowState.journalRestarting.axToken,
                severity: .warning,
                reason: nil
            )
        case .setupNeeded:
            return JournalRuntimeSettingsPresentation(
                shortText: UICopy.JOURNAL_STATUS_SETUP_NEEDED,
                axValue: MenubarStatusRowState.journalSetupNeeded.axToken,
                severity: .attention,
                reason: nil
            )
        case .stopped(let diagnostic):
            return JournalRuntimeSettingsPresentation(
                shortText: UICopy.JOURNAL_STATUS_NEEDS_ATTENTION,
                axValue: MenubarStatusRowState.journalStopped.axToken,
                severity: .attention,
                reason: diagnostic.outputExcerpt
            )
        case .unknown(let diagnostic):
            return JournalRuntimeSettingsPresentation(
                shortText: UICopy.JOURNAL_STATUS_NEEDS_ATTENTION,
                axValue: MenubarStatusRowState.journalUnknown.axToken,
                severity: .attention,
                reason: diagnostic.outputExcerpt
            )
        }
    }
}
