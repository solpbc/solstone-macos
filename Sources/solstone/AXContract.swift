// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import UpdateKit

enum AXContract {
    static let idPattern = #"^(about|journal|menubar|settings|updates)(\.[a-z][a-zA-Z0-9-]*)+$"#
    static let tokenPattern = #"^[a-z][a-z_]*$"#

    private static let generatedMarker =
        "DO NOT EDIT. Generated from AXID.swift + AXToken.swift. Run `make ax-contract` to regenerate; `make ci` fails on drift."

    static let staticIDs: [String] = [
        AXID.Menubar.statusIconState,
        AXID.Menubar.statusIconOverlayState,
        AXID.Menubar.statusRowState,
        AXID.Menubar.permissionsButton,
        AXID.Menubar.errorButton,
        AXID.Menubar.journalState,
        AXID.Menubar.journalMigrationNeededButton,
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
        AXID.Journal.Browser.webView,
        AXID.Journal.Browser.navigationState,
        AXID.Journal.Browser.retry,
        AXID.Settings.Permissions.screenRecordingState,
        AXID.Settings.Permissions.screenRecordingEnable,
        AXID.Settings.Permissions.screenRecordingRestartNow,
        AXID.Settings.Permissions.screenRecordingRestartCountdown,
        AXID.Settings.Permissions.microphoneState,
        AXID.Settings.Permissions.microphoneGrantAccess,
        AXID.Settings.Permissions.systemSettingsOpen,
        AXID.Settings.Permissions.nextConnectJournal,
        AXID.Settings.Observer.startAtLogin,
        AXID.Settings.Observer.notificationDeniedState,
        AXID.Settings.Observer.storageUsedState,
        AXID.Settings.Observer.cacheRetentionPicker,
        AXID.Settings.Observer.cacheRetentionState,
        AXID.Settings.Observer.cacheFolderOpen,
        AXID.Settings.Service.prereqPermissions,
        AXID.Settings.Service.journalNameState,
        AXID.Settings.Service.journalMarkState,
        AXID.Settings.Service.journalConnectionState,
        AXID.Settings.Service.journalRelink,
        AXID.Settings.Service.localJournalDiscoveryState,
        AXID.Settings.Service.localJournalDiscoveryPathState,
        AXID.Settings.Service.localJournalConfirm,
        AXID.Settings.Service.createJournalThisMac,
        AXID.Settings.Service.createJournalState,
        AXID.Settings.Service.pairJournalAnotherDevice,
        AXID.Settings.Service.journalHandoffBanner,
        AXID.Settings.Service.journalHandoffStart,
        AXID.Settings.Service.journalHandoffState,
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
        AXID.Settings.Service.pairingRelayAccessState,
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
        AXID.Settings.Status.tryAgain,
        AXID.Settings.Status.setupVerdictState,
        AXID.Settings.Status.setupSolAppState,
        AXID.Settings.Status.setupSolAppAction,
        AXID.Settings.Status.setupJournalAppState,
        AXID.Settings.Status.setupJournalAppAction,
        AXID.Settings.Status.setupJournalLinkState,
        AXID.Settings.Status.setupJournalLinkAction,
        AXID.Settings.Status.setupCommandLineToolsState,
        AXID.Settings.Status.setupCommandLineToolsAction,
        AXID.Settings.Status.setupScreenRecordingState,
        AXID.Settings.Status.setupScreenRecordingAction,
        AXID.Settings.Status.setupMicrophoneState,
        AXID.Settings.Status.setupMicrophoneAction,
        AXID.Settings.Status.setupLastSyncState,
        AXID.Settings.Status.setupManageJournal,
        AXID.Settings.Status.setupAppVersionState,
        AXID.Settings.Status.uploadJournalState,
        AXID.Settings.Status.uploadState,
        AXID.Settings.Status.uploadChecked,
        AXID.Settings.Status.uploadTotal,
        AXID.Settings.Status.uploadPending,
        AXID.Settings.Status.pauseSync,
        AXID.Settings.Status.lastSyncedState,
        AXID.Settings.Status.lastErrorState,
        AXID.Settings.Status.resyncAll,
        AXID.Settings.Status.storageSettings,
        AXID.Settings.Status.debugOneMinuteSegments,
        AXID.Settings.Status.debugKeepRejectedAudio,
        AXID.Settings.Help.agentInstructions,
        AXID.Settings.Help.copyAgentInstructions,
        AXID.Settings.Help.iconStateRecording,
        AXID.Settings.Help.iconStateOffline,
        AXID.Settings.Help.iconStatePaused,
        AXID.Settings.Help.iconStateError,
        AXID.Settings.Help.iconStateConnecting,
        AXID.Settings.Help.iconStateAttention,
        AXID.Settings.Help.supportSite,
        AXID.Settings.Help.supportEmail,
        AXID.Settings.Help.versionState,
        UpdatesAXID.statusState,
        UpdatesAXID.unavailable,
        UpdatesAXID.notRunning,
        UpdatesAXID.notRunningRetry,
        UpdatesAXID.notRunningReason,
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

        return ids
    }

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
            "MenubarIconOverlayState": MenubarIconOverlayState.allCases.map(\.axToken),
            "MenubarStatusRowState": MenubarStatusRowState.allCases.map(\.axToken),
            "SettingsObservationAXState": SettingsObservationAXState.allCases.map(\.axToken),
            "SetupCheckRowAXState": SetupCheckRowAXState.allCases.map(\.axToken),
            "SetupGroupVerdictAXState": SetupGroupVerdictAXState.allCases.map(\.axToken),
            "SidebarBadgeState": SettingsView.SidebarBadgeState.allCases.map(\.axToken),
            "UploadCoordinator.Status": UploadCoordinator.Status.axTokens,
            "ConnectionTestState": ConnectionTestState.axTokens,
            "PairingFlowState": PairingFlowState.axTokens,
            "PairingFailure": PairingFailure.axTokens,
            "PairingConnectionAXState": PairingConnectionAXState.axTokens,
            "PairingRelayAccessAXState": PairingRelayAccessAXState.axTokens,
            "JournalHandoffAXState": JournalHandoffAXState.allCases.map(\.axToken),
            "FreshJournalAXState": FreshJournalAXState.allCases.map(\.axToken),
            "LocalJournalDiscoveryAXState": LocalJournalDiscoveryAXState.allCases.map(\.axToken),
            "JournalWindowAXState": JournalWindowAXState.allCases.map(\.axToken),
            "UpdateActivity": UpdateActivity.axTokens,
            "FrequencyOption": FrequencyOption.allCases.map(\.rawValue),
            "UpdateStatus": UpdateStatus.axTokens
        ]
    }

    static var states: [String: StateBinding] {
        [
            AXID.Menubar.statusIconState: .enum("MenubarIconState"),
            AXID.Menubar.statusIconOverlayState: .enum("MenubarIconOverlayState"),
            AXID.Menubar.statusRowState: .enum("MenubarStatusRowState"),
            AXID.Menubar.journalState: .enum("MenubarStatusRowState"),
            AXID.Journal.Browser.navigationState: .enum("JournalWindowAXState"),
            "settings.sidebar.tab.{tab}.state": .enum("SidebarBadgeState"),
            AXID.Settings.Permissions.screenRecordingState: .enum("AXPermissionState"),
            AXID.Settings.Permissions.screenRecordingRestartCountdown: .numeric,
            AXID.Settings.Permissions.microphoneState: .enum("AXPermissionState"),
            AXID.Settings.Observer.notificationDeniedState: .freeform,
            AXID.Settings.Observer.storageUsedState: .numeric,
            AXID.Settings.Observer.cacheRetentionState: .numeric,
            AXID.Settings.Service.journalNameState: .freeform,
            AXID.Settings.Service.journalMarkState: .freeform,
            AXID.Settings.Service.journalConnectionState: .enum("PairingConnectionAXState"),
            AXID.Settings.Service.journalHandoffState: .enum("JournalHandoffAXState"),
            AXID.Settings.Service.localJournalDiscoveryState: .enum("LocalJournalDiscoveryAXState"),
            AXID.Settings.Service.localJournalDiscoveryPathState: .freeform,
            AXID.Settings.Service.createJournalState: .enum("FreshJournalAXState"),
            AXID.Settings.Service.externalConnectionTestState: .enum("ConnectionTestState"),
            AXID.Settings.Service.pairingFlowState: .enum("PairingFlowState"),
            AXID.Settings.Service.pairingFailureState: .enum("PairingFailure"),
            AXID.Settings.Service.pairingConnectionState: .enum("PairingConnectionAXState"),
            AXID.Settings.Service.pairingRelayAccessState: .enum("PairingRelayAccessAXState"),
            AXID.Settings.Microphones.gainState: .numeric,
            AXID.Settings.Status.healthSummary: .freeform,
            AXID.Settings.Status.observingState: .enum("SettingsObservationAXState"),
            AXID.Settings.Status.nextSegmentSeconds: .numeric,
            AXID.Settings.Status.setupVerdictState: .enum("SetupGroupVerdictAXState"),
            AXID.Settings.Status.setupSolAppState: .enum("SetupCheckRowAXState"),
            AXID.Settings.Status.setupJournalAppState: .enum("SetupCheckRowAXState"),
            AXID.Settings.Status.setupJournalLinkState: .enum("SetupCheckRowAXState"),
            AXID.Settings.Status.setupCommandLineToolsState: .enum("SetupCheckRowAXState"),
            AXID.Settings.Status.setupScreenRecordingState: .enum("SetupCheckRowAXState"),
            AXID.Settings.Status.setupMicrophoneState: .enum("SetupCheckRowAXState"),
            AXID.Settings.Status.setupLastSyncState: .enum("SetupCheckRowAXState"),
            AXID.Settings.Status.setupAppVersionState: .freeform,
            AXID.Settings.Status.uploadJournalState: .freeform,
            AXID.Settings.Status.uploadState: .enum("UploadCoordinator.Status"),
            AXID.Settings.Status.uploadChecked: .numeric,
            AXID.Settings.Status.uploadTotal: .numeric,
            AXID.Settings.Status.uploadPending: .numeric,
            AXID.Settings.Status.lastSyncedState: .numeric,
            AXID.Settings.Status.lastErrorState: .freeform,
            AXID.Settings.Help.versionState: .freeform,
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
        let keys = Set(
            enumerableIDs
                .filter { $0.hasSuffix(".state") }
                .map(stateKey(for:))
        )
        return keys
    }

    static func stateKey(for id: String) -> String {
        if id.hasPrefix("settings.sidebar.tab."), id.hasSuffix(".state") {
            return "settings.sidebar.tab.{tab}.state"
        }
        return id
    }

    static func generate() -> String {
        let contract = Contract(
            generated: generatedMarker,
            version: 1,
            grammar: Grammar(identifier: idPattern, token: tokenPattern),
            surfaces: ["about", "journal", "menubar", "settings", "updates"],
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
