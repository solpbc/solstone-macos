// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntime
import SolstoneCore
import UpdateKit

enum AXContract {
    static let idPattern = #"^(menubar|settings|installer|updates|about)(\.[a-z][a-zA-Z0-9-]*)+$"#
    static let tokenPattern = #"^[a-z][a-z_]*$"#

    private static let generatedMarker =
        "DO NOT EDIT. Generated from AXID.swift + AXToken.swift. Run `make ax-contract` to regenerate; `make ci` fails on drift."

    static let doctorCheckTemplate = "installer.doctor.check.{slug}"

    static let staticIDs: [String] = [
        AXID.Menubar.pendingChatButton,
        AXID.Menubar.statusIconState,
        AXID.Menubar.statusRowState,
        AXID.Menubar.permissionsButton,
        AXID.Menubar.errorButton,
        AXID.Menubar.journalState,
        AXID.Menubar.localOnlyButton,
        AXID.Menubar.offlineButton,
        AXID.Menubar.pauseMenu,
        AXID.Menubar.pauseFifteenMinutes,
        AXID.Menubar.pauseThirtyMinutes,
        AXID.Menubar.pauseOneHour,
        AXID.Menubar.pauseIndefinite,
        AXID.Menubar.resumeButton,
        AXID.Menubar.openJournalButton,
        AXID.Menubar.settingsButton,
        AXID.Menubar.aboutButton,
        AXID.Menubar.quitButton,
        AXID.Settings.Permissions.screenRecordingState,
        AXID.Settings.Permissions.screenRecordingEnable,
        AXID.Settings.Permissions.screenRecordingRestartNow,
        AXID.Settings.Permissions.screenRecordingRestartCountdown,
        AXID.Settings.Permissions.microphoneState,
        AXID.Settings.Permissions.microphoneGrantAccess,
        AXID.Settings.Permissions.systemSettingsOpen,
        AXID.Settings.Permissions.nextConnectJournal,
        AXID.Settings.Observer.startAtLogin,
        AXID.Settings.Observer.solChatNotifications,
        AXID.Settings.Observer.notificationDeniedState,
        AXID.Settings.Observer.storageUsedState,
        AXID.Settings.Observer.cacheRetentionPicker,
        AXID.Settings.Observer.cacheRetentionState,
        AXID.Settings.Observer.cacheFolderOpen,
        AXID.Settings.Service.restartRequiredBanner,
        AXID.Settings.Service.restartJournalButton,
        AXID.Settings.Service.stopJournalButton,
        AXID.Settings.Service.startJournalButton,
        AXID.Settings.Service.prereqPermissions,
        AXID.Settings.Service.journalModePicker,
        AXID.Settings.Service.journalModeState,
        AXID.Settings.Service.externalSetupGuide,
        AXID.Settings.Service.externalAddress,
        AXID.Settings.Service.externalKey,
        AXID.Settings.Service.externalTestConnection,
        AXID.Settings.Service.externalConnect,
        AXID.Settings.Service.externalConnectionTestState,
        AXID.Settings.Service.externalViewStatus,
        AXID.Settings.Service.pairingLink,
        AXID.Settings.Service.pairingConnect,
        AXID.Settings.Service.pairingUnpair,
        AXID.Settings.Service.pairingRetry,
        AXID.Settings.Service.pairingSwitchConfirm,
        AXID.Settings.Service.pairingSwitchCancel,
        AXID.Settings.Service.pairingFlowState,
        AXID.Settings.Service.pairingFailureState,
        AXID.Settings.Service.pairingConnectionState,
        AXID.Settings.Service.pairingPaidPlanLink,
        AXID.Settings.Service.pairingDisconnectConfirm,
        AXID.Settings.Service.pairingDisconnectCancel,
        AXID.Settings.Service.pairingMarkConfirm,
        AXID.Settings.Service.pairingMarkMismatch,
        AXID.Settings.Service.pairingMismatchFreshLink,
        AXID.Settings.Service.pairingMismatchSupport,
        AXID.Settings.Service.nextCheckStatus,
        AXID.Settings.Microphones.priorityList,
        AXID.Settings.Microphones.gainPicker,
        AXID.Settings.Microphones.gainState,
        AXID.Settings.Microphones.silenceMusic,
        AXID.Settings.Privacy.excludedAppsList,
        AXID.Settings.Privacy.excludedAppField,
        AXID.Settings.Privacy.excludedAppAdd,
        AXID.Settings.Privacy.titlePatternsList,
        AXID.Settings.Privacy.titlePatternField,
        AXID.Settings.Privacy.titlePatternAdd,
        AXID.Settings.Privacy.privateBrowsing,
        AXID.Settings.Status.healthSummary,
        AXID.Settings.Status.observingState,
        AXID.Settings.Status.nextSegmentSeconds,
        AXID.Settings.Status.uploadJournalState,
        AXID.Settings.Status.journalRuntimeState,
        AXID.Settings.Status.journalReadinessQueueState,
        AXID.Settings.Status.uploadState,
        AXID.Settings.Status.uploadChecked,
        AXID.Settings.Status.uploadTotal,
        AXID.Settings.Status.uploadPending,
        AXID.Settings.Status.pauseSync,
        AXID.Settings.Status.lastSyncedState,
        AXID.Settings.Status.lastErrorState,
        AXID.Settings.Status.resyncAll,
        AXID.Settings.Status.manageJournal,
        AXID.Settings.Status.bundledLastActivity,
        AXID.Settings.Status.storageSettings,
        AXID.Settings.Status.debugOneMinuteSegments,
        AXID.Settings.Status.debugKeepRejectedAudio,
        AXID.Settings.Status.appVersionState,
        AXID.Settings.Help.agentInstructions,
        AXID.Settings.Help.copyAgentInstructions,
        AXID.Settings.Help.iconStateRecording,
        AXID.Settings.Help.iconStateOffline,
        AXID.Settings.Help.iconStatePaused,
        AXID.Settings.Help.iconStateError,
        AXID.Settings.Help.supportSite,
        AXID.Settings.Help.supportEmail,
        AXID.Settings.Help.versionState,
        AXID.Installer.terminalState,
        AXID.Installer.journalPathState,
        AXID.Installer.journalTCCRestrictedState,
        AXID.Installer.journalChange,
        AXID.Installer.install,
        AXID.Installer.installedMessageState,
        AXID.Installer.openDashboard,
        AXID.Installer.externalManagedState,
        AXID.Installer.externalManagedPathState,
        AXID.Installer.autoTestState,
        AXID.Installer.autoTestRetry,
        AXID.Installer.doctorDisclosure,
        AXID.Installer.doctorRefresh,
        AXID.Installer.doctorProgressState,
        AXID.Installer.doctorChecklist,
        AXID.Installer.doctorErrorState,
        AXID.Installer.doctorRetry,
        AXID.Installer.modelDownloadProgress,
        AXID.Installer.failureSummaryState,
        AXID.Installer.failureRetry,
        AXID.Installer.failureDetails,
        AXID.Installer.failureLog,
        AXID.Installer.diagnosticCopy,
        AXID.Installer.diagnosticCopiedState,
        AXID.Installer.diagnosticHelp,
        UpdatesAXID.statusState,
        UpdatesAXID.unavailable,
        UpdatesAXID.check,
        UpdatesAXID.checkState,
        UpdatesAXID.cancel,
        UpdatesAXID.download,
        UpdatesAXID.downloadState,
        UpdatesAXID.install,
        UpdatesAXID.dismiss,
        UpdatesAXID.dismissStaged,
        UpdatesAXID.retry,
        UpdatesAXID.retryState,
        UpdatesAXID.checkAgainState,
        UpdatesAXID.releaseNotes,
        UpdatesAXID.releaseNotesOnline,
        UpdatesAXID.downloadProgress,
        UpdatesAXID.extractProgress,
        UpdatesAXID.deferredInstallState,
        UpdatesAXID.automaticChecks,
        UpdatesAXID.frequencyPicker,
        UpdatesAXID.frequencyState,
        UpdatesAXID.automaticDownloads,
        UpdatesAXID.debugStatePicker,
        AXID.About.logo,
        AXID.About.title,
        AXID.About.versionState,
        AXID.About.sourceCode,
        AXID.About.website
    ]

    static var enumerableIDs: [String] {
        var ids = staticIDs

        for tab in SettingsView.Tab.allCases {
            ids.append(AXID.Settings.Sidebar.tab(tab))
            ids.append(AXID.Settings.Sidebar.tabState(tab))
        }

        for row in InstallerRow.allCases {
            ids.append(AXID.Installer.step(row))
            ids.append(AXID.Installer.stepState(row))
            ids.append(AXID.Installer.stepCurrentStep(row))
            ids.append(AXID.Installer.stepDetails(row))
            ids.append(AXID.Installer.stepLog(row))
        }

        for step in CleanupStep.allCases {
            ids.append(AXID.Installer.cleanupStep(step))
        }

        for name in doctorCheckSampleNames {
            ids.append(AXID.Installer.doctorCheck(name))
        }

        return ids
    }

    static let doctorCheckSampleNames = [
        "Python Version",
        "journal: path / exists",
        "Sol Doctor -- GPU/Metal?"
    ]

    static var parameterizedTemplates: [ParameterizedIdentifier] {
        [
            ParameterizedIdentifier(
                template: "settings.sidebar.tab.{tab}",
                key: "SettingsView.Tab.rawValue",
                expansions: SettingsView.Tab.allCases.map(\.rawValue)
            ),
            ParameterizedIdentifier(
                template: "settings.sidebar.tab.{tab}.state",
                key: "SettingsView.Tab.rawValue",
                expansions: SettingsView.Tab.allCases.map(\.rawValue)
            ),
            ParameterizedIdentifier(
                template: "installer.step.{row}",
                key: "InstallerRow.axKey",
                expansions: InstallerRow.allCases.map(\.axKey)
            ),
            ParameterizedIdentifier(
                template: "installer.step.{row}.state",
                key: "InstallerRow.axKey",
                expansions: InstallerRow.allCases.map(\.axKey)
            ),
            ParameterizedIdentifier(
                template: "installer.step.{row}.currentStep.state",
                key: "InstallerRow.axKey",
                expansions: InstallerRow.allCases.map(\.axKey)
            ),
            ParameterizedIdentifier(
                template: "installer.step.{row}.details",
                key: "InstallerRow.axKey",
                expansions: InstallerRow.allCases.map(\.axKey)
            ),
            ParameterizedIdentifier(
                template: "installer.step.{row}.log",
                key: "InstallerRow.axKey",
                expansions: InstallerRow.allCases.map(\.axKey)
            ),
            ParameterizedIdentifier(
                template: "installer.cleanup.{cleanupStep}.state",
                key: "CleanupStep.rawValue",
                expansions: CleanupStep.allCases.map(\.rawValue)
            ),
            ParameterizedIdentifier(
                template: doctorCheckTemplate,
                key: "DoctorCheck.name (slugged)",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "settings.microphones.priority.device.{uid}",
                key: "CoreAudio device UID",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "settings.microphones.priority.toggle.{uid}",
                key: "CoreAudio device UID",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "settings.microphones.priority.remove.{uid}",
                key: "CoreAudio device UID",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "settings.privacy.excludedApps.app.{value}",
                key: "AppEntry.name",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "settings.privacy.excludedApps.remove.{value}",
                key: "AppEntry.name",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "settings.privacy.titlePatterns.pattern.{value}",
                key: "title pattern",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "settings.privacy.titlePatterns.remove.{value}",
                key: "title pattern",
                runtime: true
            )
        ].sorted { $0.template < $1.template }
    }

    static var vocabularies: [String: [String]] {
        [
            "AXPermissionState": AXPermissionState.allCases.map(\.axToken),
            "MenubarIconState": MenubarIconState.allCases.map(\.axToken),
            "MenubarStatusRowState": MenubarStatusRowState.allCases.map(\.axToken),
            "SettingsObservationAXState": SettingsObservationAXState.allCases.map(\.axToken),
            "SidebarBadgeState": SettingsView.SidebarBadgeState.allCases.map(\.axToken),
            "RowStatus": RowStatus.axTokens,
            "InstallerCardState": InstallerCardState.axTokens,
            "AutoTestState": AutoTestState.axTokens,
            "DoctorStatus": DoctorStatus.axTokens,
            "UploadCoordinator.Status": UploadCoordinator.Status.axTokens,
            "ConnectionTestState": ConnectionTestState.axTokens,
            "PairingFlowState": PairingFlowState.axTokens,
            "PairingFailure": PairingFailure.axTokens,
            "PairingConnectionAXState": PairingConnectionAXState.axTokens,
            "UpdateActivity": UpdateActivity.axTokens,
            "JournalRuntimeStatus": JournalRuntimeStatus.axTokens,
            "ServiceMode": ServiceMode.allCases.map(\.rawValue),
            "FrequencyOption": FrequencyOption.allCases.map(\.rawValue),
            "DoctorProgress": DoctorProgress.allCases.map(\.axToken),
            "UpdateStatus": UpdateStatus.axTokens
        ]
    }

    static var states: [String: StateBinding] {
        [
            AXID.Menubar.statusIconState: .enum("MenubarIconState"),
            AXID.Menubar.statusRowState: .enum("MenubarStatusRowState"),
            AXID.Menubar.journalState: .enum("MenubarStatusRowState"),
            "settings.sidebar.tab.{tab}.state": .enum("SidebarBadgeState"),
            AXID.Settings.Permissions.screenRecordingState: .enum("AXPermissionState"),
            AXID.Settings.Permissions.screenRecordingRestartCountdown: .numeric,
            AXID.Settings.Permissions.microphoneState: .enum("AXPermissionState"),
            AXID.Settings.Observer.notificationDeniedState: .freeform,
            AXID.Settings.Observer.storageUsedState: .numeric,
            AXID.Settings.Observer.cacheRetentionState: .numeric,
            AXID.Settings.Service.journalModeState: .enum("ServiceMode"),
            AXID.Settings.Service.externalConnectionTestState: .enum("ConnectionTestState"),
            AXID.Settings.Service.pairingFlowState: .enum("PairingFlowState"),
            AXID.Settings.Service.pairingFailureState: .enum("PairingFailure"),
            AXID.Settings.Service.pairingConnectionState: .enum("PairingConnectionAXState"),
            AXID.Settings.Microphones.gainState: .numeric,
            AXID.Settings.Status.healthSummary: .freeform,
            AXID.Settings.Status.observingState: .enum("SettingsObservationAXState"),
            AXID.Settings.Status.nextSegmentSeconds: .numeric,
            AXID.Settings.Status.uploadJournalState: .freeform,
            AXID.Settings.Status.journalRuntimeState: .enum("JournalRuntimeStatus"),
            AXID.Settings.Status.journalReadinessQueueState: .enum("MenubarStatusRowState"),
            AXID.Settings.Status.uploadState: .enum("UploadCoordinator.Status"),
            AXID.Settings.Status.uploadChecked: .numeric,
            AXID.Settings.Status.uploadTotal: .numeric,
            AXID.Settings.Status.uploadPending: .numeric,
            AXID.Settings.Status.lastSyncedState: .numeric,
            AXID.Settings.Status.lastErrorState: .freeform,
            AXID.Settings.Status.bundledLastActivity: .freeform,
            AXID.Settings.Status.appVersionState: .freeform,
            AXID.Settings.Help.versionState: .freeform,
            AXID.Installer.terminalState: .enum("InstallerCardState"),
            AXID.Installer.journalPathState: .freeform,
            AXID.Installer.journalTCCRestrictedState: .freeform,
            AXID.Installer.installedMessageState: .enum("InstallerCardState"),
            AXID.Installer.externalManagedState: .enum("InstallerCardState"),
            AXID.Installer.externalManagedPathState: .freeform,
            AXID.Installer.autoTestState: .enum("AutoTestState"),
            AXID.Installer.doctorProgressState: .enum("DoctorProgress"),
            AXID.Installer.doctorErrorState: .freeform,
            AXID.Installer.modelDownloadProgress: .numeric,
            AXID.Installer.failureSummaryState: .freeform,
            AXID.Installer.diagnosticCopiedState: .freeform,
            "installer.step.{row}.state": .enum("RowStatus"),
            "installer.step.{row}.currentStep.state": .freeform,
            "installer.cleanup.{cleanupStep}.state": .enum("RowStatus"),
            doctorCheckTemplate: .enum("DoctorStatus"),
            UpdatesAXID.statusState: .enum("UpdateStatus"),
            UpdatesAXID.checkState: .freeform,
            UpdatesAXID.downloadState: .freeform,
            UpdatesAXID.retryState: .freeform,
            UpdatesAXID.checkAgainState: .freeform,
            UpdatesAXID.downloadProgress: .numeric,
            UpdatesAXID.extractProgress: .numeric,
            UpdatesAXID.deferredInstallState: .freeform,
            UpdatesAXID.frequencyState: .enum("FrequencyOption"),
            // updates.debug.state is a DEBUG picker control, not a product state-value companion.
            UpdatesAXID.debugStatePicker: .freeform,
            AXID.About.versionState: .freeform
        ]
    }

    static var requiredStateKeys: Set<String> {
        var keys = Set(
            enumerableIDs
                .filter { $0.hasSuffix(".state") }
                .map(stateKey(for:))
        )
        keys.insert(doctorCheckTemplate)
        return keys
    }

    static func stateKey(for id: String) -> String {
        if id.hasPrefix("settings.sidebar.tab."), id.hasSuffix(".state") {
            return "settings.sidebar.tab.{tab}.state"
        }
        if id.hasPrefix("installer.step."), id.hasSuffix(".currentStep.state") {
            return "installer.step.{row}.currentStep.state"
        }
        if id.hasPrefix("installer.step."), id.hasSuffix(".state") {
            return "installer.step.{row}.state"
        }
        if id.hasPrefix("installer.cleanup."), id.hasSuffix(".state") {
            return "installer.cleanup.{cleanupStep}.state"
        }
        if id.hasPrefix("installer.doctor.check.") {
            return doctorCheckTemplate
        }
        return id
    }

    static func generate() -> String {
        let contract = Contract(
            generated: generatedMarker,
            version: 1,
            grammar: Grammar(identifier: idPattern, token: tokenPattern),
            surfaces: ["about", "installer", "menubar", "settings", "updates"],
            vocabularies: vocabularies,
            identifiers: IdentifierSet(
                staticIDs: staticIDs.sorted(),
                parameterized: parameterizedTemplates
            ),
            states: states
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode(contract)
        return String(data: data, encoding: .utf8)! + "\n"
    }
}

struct ParameterizedIdentifier: Codable, Equatable {
    let template: String
    let key: String
    let expansions: [String]?
    let runtime: Bool?

    init(template: String, key: String, expansions: [String]) {
        self.template = template
        self.key = key
        self.expansions = expansions
        self.runtime = nil
    }

    init(template: String, key: String, runtime: Bool) {
        self.template = template
        self.key = key
        self.expansions = nil
        self.runtime = runtime
    }
}

struct StateBinding: Codable, Equatable {
    enum Kind: String, Codable {
        case `enum`
        case numeric
        case freeform
    }

    let kind: Kind
    let vocabulary: String?

    static func `enum`(_ vocabulary: String) -> StateBinding {
        StateBinding(kind: .enum, vocabulary: vocabulary)
    }

    static let numeric = StateBinding(kind: .numeric, vocabulary: nil)
    static let freeform = StateBinding(kind: .freeform, vocabulary: nil)
}

private struct Contract: Codable {
    let generated: String
    let version: Int
    let grammar: Grammar
    let surfaces: [String]
    let vocabularies: [String: [String]]
    let identifiers: IdentifierSet
    let states: [String: StateBinding]

    enum CodingKeys: String, CodingKey {
        case generated = "_generated"
        case version
        case grammar
        case surfaces
        case vocabularies
        case identifiers
        case states
    }
}

private struct Grammar: Codable {
    let identifier: String
    let token: String
}

private struct IdentifierSet: Codable {
    let staticIDs: [String]
    let parameterized: [ParameterizedIdentifier]

    enum CodingKeys: String, CodingKey {
        case staticIDs = "static"
        case parameterized
    }
}
