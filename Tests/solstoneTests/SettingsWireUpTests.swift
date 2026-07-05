// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("Settings WireUp")
struct SettingsWireUpTests {
    @Test func openSettingsWindowNotificationReferencesSurvivingSites() throws {
        let appSource = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let settingsSource = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let oldNotificationName = ".solMac" + "OpenSettings"

        #expect(wireUpContains(appSource, "NotificationCenter.default.post(name: .openSettingsWindow, object: nil)"))
        #expect(wireUpContains(appSource, ".onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow))"))
        #expect(wireUpContains(settingsSource, ".onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow))"))
        #expect(!appSource.contains(oldNotificationName))
        #expect(!settingsSource.contains(oldNotificationName))
    }

    // Proves registry wire-up presence, not live AX-tree attachment; device-phase AX dumps cover that.
    @Test func settingsViewReferencesExpectedAXIDs() throws {
        let source = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let references = [
            "AXID.Settings.Sidebar.tab(tab)",
            "AXID.Settings.Sidebar.tabState(tab)",
            "AXID.Settings.Permissions.screenRecordingState",
            "AXID.Settings.Permissions.screenRecordingRestartNow",
            "AXID.Settings.Permissions.screenRecordingRestartCountdown",
            "AXID.Settings.Permissions.screenRecordingEnable",
            "AXID.Settings.Permissions.microphoneState",
            "AXID.Settings.Permissions.microphoneGrantAccess",
            "AXID.Settings.Permissions.systemSettingsOpen",
            "AXID.Settings.Permissions.nextConnectJournal",
            "AXID.Settings.Observer.startAtLogin",
            "AXID.Settings.Observer.solChatNotifications",
            "AXID.Settings.Observer.notificationDeniedState",
            "AXID.Settings.Observer.storageUsedState",
            "AXID.Settings.Observer.cacheRetentionPicker",
            "AXID.Settings.Observer.cacheRetentionState",
            "AXID.Settings.Observer.cacheFolderOpen",
            "AXID.Settings.Service.nextCheckStatus",
            "AXID.Settings.Service.prereqPermissions",
            "AXID.Settings.Service.journalNameState",
            "AXID.Settings.Service.journalMarkState",
            "AXID.Settings.Service.journalConnectionState",
            "AXID.Settings.Service.journalRelink",
            "AXID.Settings.Service.localJournalDiscoveryState",
            "AXID.Settings.Service.localJournalConfirm",
            "AXID.Settings.Service.createJournalThisMac",
            "AXID.Settings.Service.pairJournalAnotherDevice",
            "AXID.Settings.Service.journalMigrationBanner",
            "AXID.Settings.Service.journalMigrationAction",
            "AXID.Settings.Service.externalSetupGuide",
            "AXID.Settings.Service.externalAddress",
            "AXID.Settings.Service.externalKey",
            "AXID.Settings.Service.externalTestConnection",
            "AXID.Settings.Service.externalConnect",
            "AXID.Settings.Service.externalConnectionTestState",
            "AXID.Settings.Service.externalViewStatus",
            "AXID.Settings.Microphones.priorityList",
            "AXID.Settings.Microphones.gainPicker",
            "AXID.Settings.Microphones.gainState",
            "AXID.Settings.Microphones.silenceMusic",
            "AXID.Settings.Microphones.deviceToggle(entry.uid)",
            "AXID.Settings.Microphones.deviceRemove(entry.uid)",
            "AXID.Settings.Microphones.device(entry.uid)",
            "AXID.Settings.Privacy.excludedAppRemove(app.name)",
            "AXID.Settings.Privacy.excludedApp(app.name)",
            "AXID.Settings.Privacy.excludedAppsList",
            "AXID.Settings.Privacy.excludedAppField",
            "AXID.Settings.Privacy.excludedAppAdd",
            "AXID.Settings.Privacy.titlePatternRemove(pattern)",
            "AXID.Settings.Privacy.titlePattern(pattern)",
            "AXID.Settings.Privacy.titlePatternsList",
            "AXID.Settings.Privacy.titlePatternField",
            "AXID.Settings.Privacy.titlePatternAdd",
            "AXID.Settings.Privacy.privateBrowsing",
            "AXID.Settings.Status.observingState",
            "AXID.Settings.Status.nextSegmentSeconds",
            "AXID.Settings.Status.uploadJournalState",
            "AXID.Settings.Status.pauseSync",
            "AXID.Settings.Status.lastSyncedState",
            "AXID.Settings.Status.lastErrorState",
            "AXID.Settings.Status.resyncAll",
            "AXID.Settings.Status.manageJournal",
            "AXID.Settings.Status.storageSettings",
            "AXID.Settings.Status.debugOneMinuteSegments",
            "AXID.Settings.Status.debugKeepRejectedAudio",
            "AXID.Settings.Status.uploadState",
            "AXID.Settings.Status.uploadChecked",
            "AXID.Settings.Status.uploadTotal",
            "AXID.Settings.Status.uploadPending",
            "AXID.Settings.Help.agentInstructions",
            "AXID.Settings.Help.copyAgentInstructions",
            "AXID.Settings.Help.iconStateRecording",
            "AXID.Settings.Help.iconStateOffline",
            "AXID.Settings.Help.iconStatePaused",
            "AXID.Settings.Help.iconStateError"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }
}
