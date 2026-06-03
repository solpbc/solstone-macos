// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("AXID registry")
struct AXIDTests {
    private let idPattern = #"^(menubar|settings|installer|updates|about)(\.[a-z][a-zA-Z0-9-]*)+$"#
    private let tokenPattern = #"^[a-z][a-z_]*$"#

    @Test func enumerableIDsMatchGrammar() {
        for id in enumerableIDs {
            #expect(matchesIDGrammar(id))
        }
    }

    @Test func idGrammarRejectsInvalidSegments() {
        #expect(!matchesIDGrammar("settings.ScreenRecording.state"))
        #expect(!matchesIDGrammar("settings.screen_recording.state"))
        #expect(!matchesIDGrammar("settings..state"))
        #expect(!matchesIDGrammar("settings.permissions.1screenRecording.state"))
    }

    @Test func enumerableIDsAreGloballyUnique() {
        #expect(Set(enumerableIDs).count == enumerableIDs.count)
    }

    @Test func runtimeKeysArePrefixStableAndInjective() {
        let firstUID = "AppleHDAEngineInput:1B,0,1,0:1"
        let secondUID = "com.EXAMPLE.Device.2"
        #expect(AXID.Settings.Microphones.device(firstUID).hasPrefix("settings.microphones.priority.device."))
        #expect(AXID.Settings.Microphones.deviceToggle(firstUID).hasPrefix("settings.microphones.priority.toggle."))
        #expect(AXID.Settings.Microphones.deviceRemove(firstUID).hasPrefix("settings.microphones.priority.remove."))
        #expect(AXID.Settings.Microphones.device(firstUID) != AXID.Settings.Microphones.device(secondUID))
        #expect(AXID.Settings.Microphones.deviceToggle(firstUID) != AXID.Settings.Microphones.deviceToggle(secondUID))
        #expect(AXID.Settings.Microphones.deviceRemove(firstUID) != AXID.Settings.Microphones.deviceRemove(secondUID))

        let firstApp = "Safari.app"
        let secondApp = "com.EXAMPLE.Editor"
        #expect(AXID.Settings.Privacy.excludedApp(firstApp).hasPrefix("settings.privacy.excludedApps.app."))
        #expect(AXID.Settings.Privacy.excludedAppRemove(firstApp).hasPrefix("settings.privacy.excludedApps.remove."))
        #expect(AXID.Settings.Privacy.excludedApp(firstApp) != AXID.Settings.Privacy.excludedApp(secondApp))
        #expect(AXID.Settings.Privacy.excludedAppRemove(firstApp) != AXID.Settings.Privacy.excludedAppRemove(secondApp))

        let firstPattern = "Private Window"
        let secondPattern = "*secret.example"
        #expect(AXID.Settings.Privacy.titlePattern(firstPattern).hasPrefix("settings.privacy.titlePatterns.pattern."))
        #expect(AXID.Settings.Privacy.titlePatternRemove(firstPattern).hasPrefix("settings.privacy.titlePatterns.remove."))
        #expect(AXID.Settings.Privacy.titlePattern(firstPattern) != AXID.Settings.Privacy.titlePattern(secondPattern))
        #expect(AXID.Settings.Privacy.titlePatternRemove(firstPattern) != AXID.Settings.Privacy.titlePatternRemove(secondPattern))
    }

    @Test func doctorSluggingIsStableForRepresentativeNames() {
        #expect(AXID.Installer.doctorCheck("Python Version") == "installer.doctor.check.python-version")
        #expect(AXID.Installer.doctorCheck("journal: path / exists") == "installer.doctor.check.journal-path-exists")
        #expect(AXID.Installer.doctorCheck("Sol Doctor -- GPU/Metal?") == "installer.doctor.check.sol-doctor-gpu-metal")
    }

    @Test func enumTokensAreExactAndMatchTokenGrammar() {
        expectToken(RowStatus.pending.axToken, "pending")
        expectToken(RowStatus.running.axToken, "running")
        expectToken(RowStatus.ok.axToken, "ok")
        expectToken(RowStatus.failed(message: "boom").axToken, "failed")

        expectToken(InstallerCardState.detecting.axToken, "detecting")
        expectToken(InstallerCardState.absent.axToken, "absent")
        expectToken(InstallerCardState.installing.axToken, "installing")
        expectToken(InstallerCardState.installedPlaceholder.axToken, "installed_placeholder")
        expectToken(InstallerCardState.done.axToken, "done")
        expectToken(InstallerCardState.installedCurrent(version: "1.2.3").axToken, "installed_current")
        expectToken(InstallerCardState.installedUnknown.axToken, "installed_unknown")
        expectToken(InstallerCardState.failed(.installSolstone(message: "boom")).axToken, "failed")
        expectToken(
            InstallerCardState.upgradeFailed(installed: "1.0.0", pinned: "2.0.0", errorDetails: "boom").axToken,
            "upgrade_failed"
        )
        expectToken(
            InstallerCardState.externallyManaged(solPath: "/usr/local/bin/sol", probe: nil).axToken,
            "externally_managed"
        )

        expectToken(AutoTestState.verifying.axToken, "verifying")
        expectToken(AutoTestState.success.axToken, "success")
        expectToken(AutoTestState.failure("boom").axToken, "failure")

        expectToken(DoctorStatus.ok.axToken, "ok")
        expectToken(DoctorStatus.warn.axToken, "warn")
        expectToken(DoctorStatus.fail.axToken, "fail")
        expectToken(DoctorStatus.skip.axToken, "skip")
        expectToken(DoctorStatus.unknown("unexpected").axToken, "unknown")

        expectToken(UploadCoordinator.Status.notSynced.axToken, "not_synced")
        expectToken(UploadCoordinator.Status.syncing(checked: 1, total: 2).axToken, "syncing")
        expectToken(UploadCoordinator.Status.synced.axToken, "synced")
        expectToken(UploadCoordinator.Status.uploading(segment: "segment").axToken, "uploading")
        expectToken(UploadCoordinator.Status.retrying(segment: "segment", attempts: 2).axToken, "retrying")
        expectToken(UploadCoordinator.Status.offline("offline").axToken, "offline")

        expectToken(ConnectionTestState.idle.axToken, "idle")
        expectToken(ConnectionTestState.testing.axToken, "testing")
        expectToken(ConnectionTestState.success.axToken, "success")
        expectToken(ConnectionTestState.failure("boom").axToken, "failure")

        expectToken(UpdateActivity.idle.axToken, "idle")
        expectToken(UpdateActivity.checking.axToken, "checking")
        expectToken(UpdateActivity.downloading(version: "1.0.0", receivedBytes: 1, totalBytes: 2).axToken, "downloading")
        expectToken(UpdateActivity.extracting(version: "1.0.0", progress: 0.5).axToken, "extracting")
        expectToken(UpdateActivity.readyToInstall(version: "1.0.0", releaseNotes: nil).axToken, "ready_to_install")
        expectToken(UpdateActivity.installing(version: "1.0.0").axToken, "installing")

        expectToken(SettingsView.SidebarBadgeState.attention.axToken, "attention")
        expectToken(SettingsView.SidebarBadgeState.done.axToken, "done")
        expectToken(SettingsView.SidebarBadgeState.blank.axToken, "none")

        expectToken(AXPermissionState.granted.axToken, "granted")
        expectToken(AXPermissionState.denied.axToken, "denied")
        expectToken(AXPermissionState.waiting.axToken, "waiting")

        expectToken(MenubarIconState.recording.axToken, "recording")
        expectToken(MenubarIconState.offline.axToken, "offline")
        expectToken(MenubarIconState.paused.axToken, "paused")
        expectToken(MenubarIconState.error.axToken, "error")

        expectToken(MenubarStatusRowState.permissions.axToken, "permissions")
        expectToken(MenubarStatusRowState.error.axToken, "error")
        expectToken(MenubarStatusRowState.pipelineDead.axToken, "pipeline_dead")
        expectToken(MenubarStatusRowState.pipelineRestarting.axToken, "pipeline_restarting")
        expectToken(MenubarStatusRowState.pipelineMissing.axToken, "pipeline_missing")
        expectToken(MenubarStatusRowState.localOnly.axToken, "local_only")
        expectToken(MenubarStatusRowState.offline.axToken, "offline")
        expectToken(MenubarStatusRowState.paused.axToken, "paused")
        expectToken(MenubarStatusRowState.observing.axToken, "observing")
        expectToken(MenubarStatusRowState.stopped.axToken, "stopped")

        expectToken(SettingsObservationAXState.observing.axToken, "observing")
        expectToken(SettingsObservationAXState.paused.axToken, "paused")
        expectToken(SettingsObservationAXState.stopped.axToken, "stopped")
    }

    @Test func menubarIconStateOwnsIconNames() {
        #expect(MenubarIconState.recording.iconName == "sol-ring-template")
        #expect(MenubarIconState.offline.iconName == "sol-ring-icon-half-template")
        #expect(MenubarIconState.paused.iconName == "sol-ring-icon-paused-template")
        #expect(MenubarIconState.error.iconName == "sol-ring-icon-error-template")
    }

    @Test func numericValueHelpersPublishRawIntegers() {
        #expect(axIntegerString(42) == "42")
        #expect(axPercentString(-0.5) == "0")
        #expect(axPercentString(0.5) == "50")
        #expect(axPercentString(1.5) == "100")
        #expect(axDownloadPercentString(receivedBytes: 25, totalBytes: 100) == "25")
        #expect(axDownloadPercentString(receivedBytes: 25, totalBytes: nil) == "0")
        #expect(
            axModelDownloadPercentString(
                .running(SubprocessProgress(phase: "models", stepIndex: 2, stepTotal: 4))
            ) == "50"
        )
        #expect(
            axModelDownloadPercentString(
                .running(SubprocessProgress(phase: "models", stepIndex: 8, stepTotal: 4))
            ) == "100"
        )
        #expect(axModelDownloadPercentString(.done) == "100")
    }

    @Test func viewsDoNotUseInlineIdentifierOrValueLiterals() throws {
        let root = URL(fileURLWithPath: "Sources/solstone", isDirectory: true)
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)!
        var matches: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "AXID.swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for pattern in forbiddenLiteralPatterns where containsForbiddenAccessibilityLiteral(in: source, pattern: pattern) {
                matches.append("\(url.path): \(pattern)")
            }
        }

        #expect(matches.isEmpty)
    }

    @Test func literalGuardPatternsCatchExpectedViolations() {
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityIdentifier("foo")"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityIdentifier ( "foo" )"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityValue("ok")"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityValue ( "ok" )"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityValue(Text("ok"))"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityValue ( Text ( "ok" ) )"#))
        #expect(!containsForbiddenAccessibilityLiteral(in: ".accessibilityIdentifier(AXID.Settings.Status.uploadState)"))
        #expect(!containsForbiddenAccessibilityLiteral(in: ".accessibilityValue(status.axToken)"))
    }

    private func expectToken(_ token: String, _ expected: String) {
        #expect(token == expected)
        #expect(token.range(of: tokenPattern, options: .regularExpression) != nil)
    }

    private func matchesIDGrammar(_ id: String) -> Bool {
        id.range(of: idPattern, options: .regularExpression) != nil
    }

    private var forbiddenLiteralPatterns: [String] {
        [
            #"\.accessibilityIdentifier\s*\(\s*""#,
            #"\.accessibilityValue\s*\(\s*""#,
            #"\.accessibilityValue\s*\(\s*Text\s*\(\s*""#
        ]
    }

    private func containsForbiddenAccessibilityLiteral(in source: String) -> Bool {
        forbiddenLiteralPatterns.contains { containsForbiddenAccessibilityLiteral(in: source, pattern: $0) }
    }

    private func containsForbiddenAccessibilityLiteral(in source: String, pattern: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }

    private var settingsTabs: [SettingsView.Tab] {
        [
            .permissions,
            .observer,
            .service,
            .microphones,
            .privacy,
            .status,
            .updates,
            .help
        ]
    }

    private var enumerableIDs: [String] {
        var ids = staticIDs

        for tab in settingsTabs {
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

        for name in ["Python Version", "journal: path / exists", "Sol Doctor -- GPU/Metal?"] {
            ids.append(AXID.Installer.doctorCheck(name))
        }

        return ids
    }

    private var staticIDs: [String] {
        [
            AXID.Menubar.pendingChatButton,
            AXID.Menubar.statusIconState,
            AXID.Menubar.statusRowState,
            AXID.Menubar.permissionsButton,
            AXID.Menubar.errorButton,
            AXID.Menubar.pipelineState,
            AXID.Menubar.localOnlyButton,
            AXID.Menubar.offlineButton,
            AXID.Menubar.pauseMenu,
            AXID.Menubar.pauseFifteenMinutes,
            AXID.Menubar.pauseThirtyMinutes,
            AXID.Menubar.pauseOneHour,
            AXID.Menubar.pauseIndefinite,
            AXID.Menubar.resumeButton,
            AXID.Menubar.startObservingButton,
            AXID.Menubar.restartPipelineButton,
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
            AXID.Settings.Status.observingState,
            AXID.Settings.Status.nextSegmentSeconds,
            AXID.Settings.Status.uploadJournalState,
            AXID.Settings.Status.uploadState,
            AXID.Settings.Status.uploadChecked,
            AXID.Settings.Status.uploadTotal,
            AXID.Settings.Status.uploadPending,
            AXID.Settings.Status.pauseSync,
            AXID.Settings.Status.lastSyncedState,
            AXID.Settings.Status.lastErrorState,
            AXID.Settings.Status.resyncAll,
            AXID.Settings.Status.configureJournal,
            AXID.Settings.Status.debugOneMinuteSegments,
            AXID.Settings.Status.debugKeepRejectedAudio,
            AXID.Settings.Help.agentInstructions,
            AXID.Settings.Help.copyAgentInstructions,
            AXID.Settings.Help.iconStateRecording,
            AXID.Settings.Help.iconStateOffline,
            AXID.Settings.Help.iconStatePaused,
            AXID.Settings.Help.iconStateError,
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
            AXID.Updates.statusState,
            AXID.Updates.unavailable,
            AXID.Updates.check,
            AXID.Updates.cancel,
            AXID.Updates.download,
            AXID.Updates.install,
            AXID.Updates.dismiss,
            AXID.Updates.retry,
            AXID.Updates.releaseNotes,
            AXID.Updates.releaseNotesOnline,
            AXID.Updates.downloadProgress,
            AXID.Updates.extractProgress,
            AXID.Updates.deferredInstallState,
            AXID.Updates.automaticChecks,
            AXID.Updates.frequencyPicker,
            AXID.Updates.frequencyState,
            AXID.Updates.automaticDownloads,
            AXID.Updates.debugStatePicker,
            AXID.About.logo,
            AXID.About.title,
            AXID.About.versionState,
            AXID.About.sourceCode,
            AXID.About.website
        ]
    }
}
