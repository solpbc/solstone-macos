// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UpdateKit

enum AXContract {
    static let idPattern = #"^(journal|updates)(\.[a-z][a-zA-Z0-9-]*)+$"#
    static let tokenPattern = #"^[a-z][a-z_]*$"#

    private static let generatedMarker =
        "DO NOT EDIT. Generated from Sources/journal/AXID.swift + AXToken.swift. Run `make ax-contract` to regenerate; `make ci` fails on drift."

    static let staticIDs: [String] = [
        AXID.Journal.Home.markCard,
        AXID.Journal.Home.nameState,
        AXID.Journal.Home.runDisplayGlanceState,
        AXID.Journal.Home.openJournal,
        AXID.Journal.Home.unconfiguredMessageState,
        AXID.Journal.Ritual.root,
        AXID.Journal.Ritual.routeState,
        AXID.Journal.Ritual.nameField,
        AXID.Journal.Ritual.locationField,
        AXID.Journal.Ritual.locationChoose,
        AXID.Journal.Ritual.nameLocationContinue,
        AXID.Journal.Ritual.nameLocationErrorState,
        AXID.Journal.Ritual.setupProgress,
        AXID.Journal.Ritual.setupStepState,
        AXID.Journal.Ritual.setupLogState,
        AXID.Journal.Ritual.setupErrorState,
        AXID.Journal.Ritual.setupRetry,
        AXID.Journal.Ritual.markCard,
        AXID.Journal.Ritual.markTryAnother,
        AXID.Journal.Ritual.markLock,
        AXID.Journal.Ritual.markLoadingState,
        AXID.Journal.Ritual.markLockedState,
        AXID.Journal.Ritual.markErrorState,
        AXID.Journal.Ritual.finalizeProgressState,
        AXID.Journal.Ritual.finalizeWarningsState,
        AXID.Journal.Ritual.finalizeErrorState,
        AXID.Journal.Ritual.finalizeRetry,
        AXID.Journal.Adopt.root,
        AXID.Journal.Adopt.statusState,
        AXID.Journal.Adopt.messageState,
        AXID.Journal.Adopt.locationPathState,
        AXID.Journal.Adopt.continueButton,
        AXID.Journal.Adopt.errorState,
        AXID.Journal.Pane.nameField,
        AXID.Journal.Pane.nameSave,
        AXID.Journal.Pane.locationPathState,
        AXID.Journal.Pane.diskUsageState,
        AXID.Journal.RunState.start,
        AXID.Journal.RunState.stop,
        AXID.Journal.RunState.restart,
        AXID.Journal.RunState.displayState,
        AXID.Journal.RunState.blockedReasonState,
        AXID.Journal.RunState.healthState,
        AXID.Journal.RunState.runtimeVersionState,
        AXID.Journal.RunState.appVersionState,
        AXID.Journal.Backup.openBackup,
        AXID.Journal.Backup.messageState,
        AXID.Journal.Startup.launchAtLogin,
        AXID.Journal.Startup.launchAtLoginState,
        AXID.Journal.Devices.root,
        AXID.Journal.Devices.loadState,
        AXID.Journal.Devices.yourDevicesHeader,
        AXID.Journal.Devices.yourDevicesCountState,
        AXID.Journal.Devices.peerJournalsHeader,
        AXID.Journal.Devices.peerJournalsCountState,
        AXID.Journal.Devices.addDevice,
        AXID.Journal.Devices.Pairing.sheet,
        AXID.Journal.Devices.Pairing.linkField,
        AXID.Journal.Devices.Pairing.copyLink,
        AXID.Journal.Devices.Pairing.copyLinkCopiedState,
        AXID.Journal.Devices.Pairing.qr,
        AXID.Journal.Devices.Pairing.countdown,
        AXID.Journal.Devices.Pairing.countdownState,
        AXID.Journal.Devices.Pairing.status,
        AXID.Journal.Devices.Pairing.statusState,
        AXID.Journal.Devices.Pairing.reopen,
        AXID.Journal.Devices.RevokeConfirm.dialog,
        AXID.Journal.Devices.RevokeConfirm.messageState,
        AXID.Journal.Devices.RevokeConfirm.confirm,
        AXID.Journal.Devices.RevokeConfirm.cancel,
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
        UpdatesAXID.debugStatePicker
    ]

    static var enumerableIDs: [String] {
        var ids = staticIDs
        for pane in JournalPane.allCases {
            ids.append(AXID.Journal.Sidebar.tab(pane))
            ids.append(AXID.Journal.Sidebar.tabState(pane))
        }
        return ids
    }

    static var parameterizedTemplates: [ParameterizedIdentifier] {
        [
            ParameterizedIdentifier(
                template: "journal.sidebar.tab.{pane}",
                key: "JournalPane.rawValue",
                expansions: JournalPane.allCases.map(\.rawValue)
            ),
            ParameterizedIdentifier(
                template: "journal.sidebar.tab.{pane}.state",
                key: "JournalPane.rawValue",
                expansions: JournalPane.allCases.map(\.rawValue)
            ),
            ParameterizedIdentifier(
                template: "journal.devices.row.fingerprint-{fingerprint}",
                key: "DeviceRow.fingerprint",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "journal.devices.row.fingerprint-{fingerprint}.label",
                key: "DeviceRow.fingerprint",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "journal.devices.row.fingerprint-{fingerprint}.detail.state",
                key: "DeviceRow.fingerprint",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "journal.devices.row.fingerprint-{fingerprint}.rename.field",
                key: "DeviceRow.fingerprint",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "journal.devices.row.fingerprint-{fingerprint}.rename.save",
                key: "DeviceRow.fingerprint",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "journal.devices.row.fingerprint-{fingerprint}.rename.error.state",
                key: "DeviceRow.fingerprint",
                runtime: true
            ),
            ParameterizedIdentifier(
                template: "journal.devices.row.fingerprint-{fingerprint}.revoke",
                key: "DeviceRow.fingerprint",
                runtime: true
            )
        ].sorted { $0.template < $1.template }
    }

    static var vocabularies: [String: [String]] {
        [
            "JournalSidebarTabState": JournalSidebarTabState.axTokens,
            "JournalRunDisplay": JournalRunDisplay.axTokens,
            "JournalHealthDisplay": JournalHealthDisplay.axTokens,
            "JournalEnabledState": JournalEnabledState.axTokens,
            "JournalDevicesLoadState": JournalDevicesLoadState.axTokens,
            "JournalDevicesPairingState": PairingState.axTokens,
            "JournalDevicesCopiedState": JournalDevicesCopiedState.axTokens,
            "JournalFirstRunRouteState": JournalFirstRunRouteState.axTokens,
            "JournalFirstRunBusyState": JournalFirstRunBusyState.axTokens,
            "JournalFirstRunMarkState": JournalFirstRunMarkState.axTokens,
            "JournalAdoptState": JournalAdoptState.axTokens,
            "UpdateActivity": UpdateActivity.axTokens,
            "FrequencyOption": FrequencyOption.allCases.map(\.rawValue),
            "UpdateStatus": UpdateStatus.axTokens
        ]
    }

    static var states: [String: StateBinding] {
        [
            "journal.sidebar.tab.{pane}.state": .enum("JournalSidebarTabState"),
            AXID.Journal.Home.nameState: .freeform,
            AXID.Journal.Home.runDisplayGlanceState: .enum("JournalRunDisplay"),
            AXID.Journal.Home.unconfiguredMessageState: .freeform,
            AXID.Journal.Ritual.routeState: .enum("JournalFirstRunRouteState"),
            AXID.Journal.Ritual.nameLocationErrorState: .freeform,
            AXID.Journal.Ritual.setupStepState: .freeform,
            AXID.Journal.Ritual.setupLogState: .freeform,
            AXID.Journal.Ritual.setupErrorState: .freeform,
            AXID.Journal.Ritual.markLoadingState: .enum("JournalFirstRunBusyState"),
            AXID.Journal.Ritual.markLockedState: .enum("JournalFirstRunMarkState"),
            AXID.Journal.Ritual.markErrorState: .freeform,
            AXID.Journal.Ritual.finalizeProgressState: .enum("JournalFirstRunBusyState"),
            AXID.Journal.Ritual.finalizeWarningsState: .freeform,
            AXID.Journal.Ritual.finalizeErrorState: .freeform,
            AXID.Journal.Adopt.statusState: .enum("JournalAdoptState"),
            AXID.Journal.Adopt.messageState: .freeform,
            AXID.Journal.Adopt.locationPathState: .freeform,
            AXID.Journal.Adopt.errorState: .freeform,
            AXID.Journal.Pane.locationPathState: .freeform,
            AXID.Journal.Pane.diskUsageState: .numeric,
            AXID.Journal.RunState.displayState: .enum("JournalRunDisplay"),
            AXID.Journal.RunState.blockedReasonState: .freeform,
            AXID.Journal.RunState.healthState: .enum("JournalHealthDisplay"),
            AXID.Journal.RunState.runtimeVersionState: .freeform,
            AXID.Journal.RunState.appVersionState: .freeform,
            AXID.Journal.Backup.messageState: .freeform,
            AXID.Journal.Startup.launchAtLoginState: .enum("JournalEnabledState"),
            AXID.Journal.Devices.loadState: .enum("JournalDevicesLoadState"),
            AXID.Journal.Devices.yourDevicesCountState: .numeric,
            AXID.Journal.Devices.peerJournalsCountState: .numeric,
            "journal.devices.row.fingerprint-{fingerprint}.detail.state": .freeform,
            "journal.devices.row.fingerprint-{fingerprint}.rename.error.state": .freeform,
            AXID.Journal.Devices.Pairing.copyLinkCopiedState: .enum("JournalDevicesCopiedState"),
            AXID.Journal.Devices.Pairing.countdownState: .numeric,
            AXID.Journal.Devices.Pairing.statusState: .enum("JournalDevicesPairingState"),
            AXID.Journal.Devices.RevokeConfirm.messageState: .freeform,
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
            UpdatesAXID.debugStatePicker: .freeform
        ]
    }

    static var requiredStateKeys: Set<String> {
        var keys = Set(
            enumerableIDs
                .filter { $0.hasSuffix(".state") }
                .map(stateKey(for:))
        )
        for template in parameterizedTemplates where template.template.hasSuffix(".state") {
            keys.insert(template.template)
        }
        return keys
    }

    static func stateKey(for id: String) -> String {
        if id.hasPrefix("journal.sidebar.tab."), id.hasSuffix(".state") {
            return "journal.sidebar.tab.{pane}.state"
        }
        if id.hasPrefix("journal.devices.row.fingerprint-"), id.hasSuffix(".rename.error.state") {
            return "journal.devices.row.fingerprint-{fingerprint}.rename.error.state"
        }
        if id.hasPrefix("journal.devices.row.fingerprint-"), id.hasSuffix(".detail.state") {
            return "journal.devices.row.fingerprint-{fingerprint}.detail.state"
        }
        return id
    }

    static func generate() -> String {
        let contract = Contract(
            generated: generatedMarker,
            version: 1,
            grammar: Grammar(identifier: idPattern, token: tokenPattern),
            surfaces: ["journal", "updates"],
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
