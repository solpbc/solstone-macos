// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum AXID {
    enum Menubar {
        static let pendingChatButton = "menubar.chat.pending"
        static let statusIconState = "menubar.status.icon.state"
        static let statusRowState = "menubar.status.row.state"
        static let permissionsButton = "menubar.status.permissions"
        static let errorButton = "menubar.status.error"
        static let journalState = "menubar.status.journal.state"
        static let localOnlyButton = "menubar.status.localOnly"
        static let offlineButton = "menubar.status.offline"
        static let pauseMenu = "menubar.pause.menu"
        static let pauseFifteenMinutes = "menubar.pause.fifteenMinutes"
        static let pauseThirtyMinutes = "menubar.pause.thirtyMinutes"
        static let pauseOneHour = "menubar.pause.oneHour"
        static let pauseIndefinite = "menubar.pause.indefinite"
        static let resumeButton = "menubar.pause.resume"
        static let openJournalButton = "menubar.navigation.openJournal"
        static let settingsButton = "menubar.navigation.settings"
        static let aboutButton = "menubar.navigation.about"
        static let quitButton = "menubar.app.quit"
    }

    enum Settings {
        enum Sidebar {
            static func tab(_ tab: SettingsView.Tab) -> String {
                "settings.sidebar.tab.\(tab.rawValue)"
            }

            static func tabState(_ tab: SettingsView.Tab) -> String {
                "settings.sidebar.tab.\(tab.rawValue).state"
            }
        }

        enum Permissions {
            static let screenRecordingState = "settings.permissions.screenRecording.state"
            static let screenRecordingEnable = "settings.permissions.screenRecording.enable"
            static let screenRecordingRestartNow = "settings.permissions.screenRecording.restartNow"
            static let screenRecordingRestartCountdown = "settings.permissions.screenRecording.restartCountdown.state"
            static let microphoneState = "settings.permissions.microphone.state"
            static let microphoneGrantAccess = "settings.permissions.microphone.grantAccess"
            static let systemSettingsOpen = "settings.permissions.systemSettings.open"
            static let nextConnectJournal = "settings.permissions.next.connectJournal"
        }

        enum Observer {
            static let startAtLogin = "settings.observer.general.startAtLogin"
            static let solChatNotifications = "settings.observer.notifications.solChat"
            static let notificationDeniedState = "settings.observer.notifications.denied.state"
            static let storageUsedState = "settings.observer.storage.used.state"
            static let cacheRetentionPicker = "settings.observer.storage.cacheRetention"
            static let cacheRetentionState = "settings.observer.storage.cacheRetention.state"
            static let cacheFolderOpen = "settings.observer.storage.cacheFolder.open"
        }

        enum Service {
            static let restartRequiredBanner = "settings.service.restartRequired.banner"
            static let restartJournalButton = "settings.service.journal.restart"
            static let stopJournalButton = "settings.service.journal.stop"
            static let startJournalButton = "settings.service.journal.start"
            static let prereqPermissions = "settings.service.prereq.permissions"
            static let journalModePicker = "settings.service.journalMode.picker"
            static let journalModeState = "settings.service.journalMode.state"
            static let externalSetupGuide = "settings.service.external.setupGuide"
            static let externalAddress = "settings.service.external.address"
            static let externalKey = "settings.service.external.key"
            static let externalTestConnection = "settings.service.external.testConnection"
            static let externalConnect = "settings.service.external.connect"
            static let externalConnectionTestState = "settings.service.external.connectionTest.state"
            static let externalViewStatus = "settings.service.external.viewStatus"
            static let pairingLink = "settings.service.pairing.link"
            static let pairingConnect = "settings.service.pairing.connect"
            static let pairingUnpair = "settings.service.pairing.unpair"
            static let pairingRetry = "settings.service.pairing.retry"
            static let pairingSwitchConfirm = "settings.service.pairing.switchConfirm"
            static let pairingSwitchCancel = "settings.service.pairing.switchCancel"
            static let pairingFlowState = "settings.service.pairing.flow.state"
            static let pairingFailureState = "settings.service.pairing.failure.state"
            static let pairingConnectionState = "settings.service.pairing.connection.state"
            static let pairingPaidPlanLink = "settings.service.pairing.paidPlanLink"
            static let pairingDisconnectConfirm = "settings.service.pairing.disconnectConfirm"
            static let pairingDisconnectCancel = "settings.service.pairing.disconnectCancel"
            static let pairingMarkConfirm = "settings.service.pairing.markConfirm"
            static let pairingMarkMismatch = "settings.service.pairing.markMismatch"
            static let pairingMismatchFreshLink = "settings.service.pairing.mismatchFreshLink"
            static let pairingMismatchSupport = "settings.service.pairing.mismatchSupport"
            static let nextCheckStatus = "settings.service.next.checkStatus"
        }

        enum Microphones {
            static let priorityList = "settings.microphones.priority.list"
            static let gainPicker = "settings.microphones.gain.picker"
            static let gainState = "settings.microphones.gain.state"
            static let silenceMusic = "settings.microphones.audioProcessing.silenceMusic"

            static func device(_ uid: String) -> String {
                "settings.microphones.priority.device.\(uid)"
            }

            static func deviceToggle(_ uid: String) -> String {
                "settings.microphones.priority.toggle.\(uid)"
            }

            static func deviceRemove(_ uid: String) -> String {
                "settings.microphones.priority.remove.\(uid)"
            }
        }

        enum Privacy {
            static let excludedAppsList = "settings.privacy.excludedApps.list"
            static let excludedAppField = "settings.privacy.excludedApps.field"
            static let excludedAppAdd = "settings.privacy.excludedApps.add"
            static let titlePatternsList = "settings.privacy.titlePatterns.list"
            static let titlePatternField = "settings.privacy.titlePatterns.field"
            static let titlePatternAdd = "settings.privacy.titlePatterns.add"
            static let privateBrowsing = "settings.privacy.privateBrowsing.exclude"

            static func excludedApp(_ value: String) -> String {
                "settings.privacy.excludedApps.app.\(value)"
            }

            static func excludedAppRemove(_ value: String) -> String {
                "settings.privacy.excludedApps.remove.\(value)"
            }

            static func titlePattern(_ value: String) -> String {
                "settings.privacy.titlePatterns.pattern.\(value)"
            }

            static func titlePatternRemove(_ value: String) -> String {
                "settings.privacy.titlePatterns.remove.\(value)"
            }
        }

        enum Status {
            static let healthSummary = "settings.status.health.summary.state"
            static let observingState = "settings.status.observing.state"
            static let nextSegmentSeconds = "settings.status.observing.nextSegment.state"
            static let uploadJournalState = "settings.status.upload.journal.state"
            static let journalRuntimeState = "settings.status.journal.runtime.state"
            static let journalReadinessQueueState = "settings.status.journal.readinessQueue.state"
            static let uploadState = "settings.status.upload.state"
            static let uploadChecked = "settings.status.upload.checked.state"
            static let uploadTotal = "settings.status.upload.total.state"
            static let uploadPending = "settings.status.upload.pending.state"
            static let pauseSync = "settings.status.upload.pauseSync"
            static let lastSyncedState = "settings.status.upload.lastSynced.state"
            static let lastErrorState = "settings.status.upload.lastError.state"
            static let resyncAll = "settings.status.upload.resyncAll"
            static let manageJournal = "settings.status.journal.manageJournal"
            static let bundledLastActivity = "settings.status.journal.lastActivity.state"
            static let storageSettings = "settings.status.storage.settings"
            static let debugOneMinuteSegments = "settings.status.debug.oneMinuteSegments"
            static let debugKeepRejectedAudio = "settings.status.debug.keepRejectedAudio"
            static let appVersionState = "settings.status.app.version.state"
        }

        enum Help {
            static let agentInstructions = "settings.help.agentInstructions"
            static let copyAgentInstructions = "settings.help.agentInstructions.copy"
            static let iconStateRecording = "settings.help.iconState.recording"
            static let iconStateOffline = "settings.help.iconState.offline"
            static let iconStatePaused = "settings.help.iconState.paused"
            static let iconStateError = "settings.help.iconState.error"
            static let supportSite = "settings.help.support.site"
            static let supportEmail = "settings.help.support.email"
            static let versionState = "settings.help.version.state"
        }
    }

    enum Installer {
        static let terminalState = "installer.terminalState.state"
        static let journalPathState = "installer.journal.path.state"
        static let journalTCCRestrictedState = "installer.journal.tccRestricted.state"
        static let journalChange = "installer.journal.change"
        static let install = "installer.absent.install"
        static let installedMessageState = "installer.installed.message.state"
        static let openDashboard = "installer.installed.openDashboard"
        static let externalManagedState = "installer.externalManaged.state"
        static let externalManagedPathState = "installer.externalManaged.path.state"
        static let autoTestState = "installer.autoTest.state"
        static let autoTestRetry = "installer.autoTest.retry"
        static let doctorDisclosure = "installer.doctor.disclosure"
        static let doctorRefresh = "installer.doctor.refresh"
        static let doctorProgressState = "installer.doctor.progress.state"
        static let doctorChecklist = "installer.doctor.checklist"
        static let doctorErrorState = "installer.doctor.error.state"
        static let doctorRetry = "installer.doctor.retry"
        static let modelDownloadProgress = "installer.modelDownload.state"
        static let failureSummaryState = "installer.failure.summary.state"
        static let failureRetry = "installer.failure.retry"
        static let failureDetails = "installer.failure.details"
        static let failureLog = "installer.failure.log"
        static let diagnosticCopy = "installer.failure.diagnostic.copy"
        static let diagnosticCopiedState = "installer.failure.diagnostic.copied.state"
        static let diagnosticHelp = "installer.failure.diagnostic.help"

        static func doctorCheck(_ name: String) -> String {
            "installer.doctor.check.\(slug(from: name))"
        }

        static func step(_ row: InstallerRow) -> String {
            "installer.step.\(row.axKey)"
        }

        static func stepState(_ row: InstallerRow) -> String {
            "installer.step.\(row.axKey).state"
        }

        static func stepCurrentStep(_ row: InstallerRow) -> String {
            "installer.step.\(row.axKey).currentStep.state"
        }

        static func stepDetails(_ row: InstallerRow) -> String {
            "installer.step.\(row.axKey).details"
        }

        static func stepLog(_ row: InstallerRow) -> String {
            "installer.step.\(row.axKey).log"
        }

        static func cleanupStep(_ step: CleanupStep) -> String {
            "installer.cleanup.\(step.rawValue).state"
        }

        static func slug(from name: String) -> String {
            let lowercased = name.lowercased()
            var result = ""
            var lastWasSeparator = false

            for scalar in lowercased.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    result.unicodeScalars.append(scalar)
                    lastWasSeparator = false
                } else if !lastWasSeparator {
                    result.append("-")
                    lastWasSeparator = true
                }
            }

            return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
    }

    enum Updates {
        static let statusState = "updates.status.state"
        static let unavailable = "updates.status.unavailable"
        static let check = "updates.action.check"
        static let checkState = "updates.action.check.state"
        static let cancel = "updates.action.cancel"
        static let download = "updates.action.download"
        static let downloadState = "updates.action.download.state"
        static let install = "updates.action.install"
        static let dismiss = "updates.action.dismiss"
        static let dismissStaged = "updates.action.dismissStaged"
        static let retry = "updates.action.retry"
        static let retryState = "updates.action.retry.state"
        static let checkAgainState = "updates.action.checkAgain.state"
        static let releaseNotes = "updates.releaseNotes.content"
        static let releaseNotesOnline = "updates.releaseNotes.online"
        static let downloadProgress = "updates.downloadProgress.state"
        static let extractProgress = "updates.extractProgress.state"
        static let deferredInstallState = "updates.deferredInstall.state"
        static let automaticChecks = "updates.preferences.automaticChecks"
        static let frequencyPicker = "updates.preferences.frequency"
        static let frequencyState = "updates.preferences.frequency.state"
        static let automaticDownloads = "updates.preferences.automaticDownloads"
        static let debugStatePicker = "updates.debug.state"
    }

    enum About {
        static let logo = "about.identity.logo"
        static let title = "about.identity.title"
        static let versionState = "about.identity.version.state"
        static let sourceCode = "about.link.sourceCode"
        static let website = "about.link.website"
    }
}

extension InstallerRow {
    var axKey: String {
        rawValue.replacingOccurrences(of: "row.", with: "")
    }
}
