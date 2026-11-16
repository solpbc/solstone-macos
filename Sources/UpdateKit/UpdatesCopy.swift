import Foundation

public struct UpdatesCopyProvider: Sendable {
    public let appDisplayName: String
    public let releaseNotesURL: URL
    public let deferralLine: String
    private let journalProduct: Bool

    public init(appDisplayName: String, releaseNotesURL: URL, deferralLine: String) {
        self.appDisplayName = appDisplayName
        self.releaseNotesURL = releaseNotesURL
        self.deferralLine = deferralLine
        self.journalProduct = appDisplayName == "journal"
    }

    private init(appDisplayName: String, releaseNotesURL: URL, deferralLine: String, journalProduct: Bool) {
        self.appDisplayName = appDisplayName
        self.releaseNotesURL = releaseNotesURL
        self.deferralLine = deferralLine
        self.journalProduct = journalProduct
    }

    fileprivate var isJournal: Bool { journalProduct }
}

public extension UpdatesCopyProvider {
    static let solstone = UpdatesCopyProvider(
        appDisplayName: MacStrings.macos_about_solstone(),
        releaseNotesURL: URL(string: "https://solstone.app/releases/macos")!,
        deferralLine: MacStrings.macos_updates_deferredwillcontinueafterjournalsetup(),
        journalProduct: false
    )

    static let journal = UpdatesCopyProvider(
        appDisplayName: MacStrings.macos_desktop_shared_about_pendingsettingstab(),
        releaseNotesURL: URL(string: "https://solstone.app/releases/journal-macos")!,
        deferralLine: MacStrings.macos_updates_deferredwillcontinueafteryourjournalis(),
        journalProduct: true
    )
}

public struct UpdatesCopy: Sendable {
    public let provider: UpdatesCopyProvider

    public init(provider: UpdatesCopyProvider) {
        self.provider = provider
    }

    public var tabTitle: String { MacStrings.macos_desktop_shared_settings_updates() }

    public var checkingTitle: String { MacStrings.macos_updates_checkingforupdates() }
    public var checkingSubtitle: String { MacStrings.macos_updates_lookingforthelatestversionnow() }
    public var checkingInline: String { MacStrings.macos_screenshot_checking() }

    public var errorTitle: String { MacStrings.macos_copy_settingsattentionupdatecheckfailed() }
    public func errorMessage() -> String { MacStrings.macos_updates_wecouldntcheckrightnow() }

    public func errorWithAvailableMessage(version: String) -> String {
        MacStrings.macos_updates_wecouldntcheckrightnowversion("\(version)")
    }

    public var unavailableTitle: String { MacStrings.macos_updates_updatesunavailable() }
    public var unavailableSubtitle: String {
        let host = provider.releaseNotesURL.host ?? MacStrings.macos_about_solstoneapp()
        return MacStrings.macos_updates_thisbuildcantcheckforupdates("\(host)")
    }

    public var releaseNotesTitle: String { MacStrings.macos_desktop_shared_updates_whatsnew() }
    public var releaseNotesOnlineLinkLabel: String { MacStrings.macos_desktop_shared_updates_textcontent() }
    public var releaseNotesOnlineURL: URL { provider.releaseNotesURL }
    public var finalizingSuffix: String { MacStrings.macos_updates_finalizing() }

    public var actionCheckNow: String { MacStrings.macos_desktop_shared_updates_checknow() }
    public var actionCheckAgain: String { MacStrings.macos_desktop_shared_copy_checkagain() }
    public var actionDownload: String { MacStrings.macos_desktop_shared_updates_download() }
    public var actionInstall: String { MacStrings.macos_updates_installandrestart("\(provider.appDisplayName)") }
    public var actionRelaunchToInstall: String { MacStrings.macos_updates_restarttoinstall("\(provider.appDisplayName)") }
    public var actionCancel: String { MacStrings.macos_desktop_shared_setup_cancel() }
    public var actionDismiss: String { MacStrings.macos_desktop_shared_updates_dismiss() }
    public var actionRetry: String { MacStrings.macos_desktop_shared_settings_textcontent() }
    public var actionRetrying: String { MacStrings.macos_updates_retrying() }
    public var actionLater: String { MacStrings.macos_updatescopy_later() }

    public var autoUpdateGroupTitle: String { MacStrings.macos_desktop_shared_updates_automaticupdates() }
    public var autoCheckToggleLabel: String { MacStrings.macos_desktop_shared_updates_checkforupdatesautomatically() }
    public var automaticChecksOff: String { MacStrings.macos_updates_automaticchecksareoffyoucanstill() }
    public var actionEnableAutomaticChecks: String { MacStrings.macos_updates_enableautomaticchecks() }
    public var autoDownloadToggleLabel: String { MacStrings.macos_desktop_shared_updates_downloadupdatesinthebackground() }
    public var frequencyPickerLabel: String { MacStrings.macos_desktop_shared_updates_howoften() }
    public var frequencyDay: String { MacStrings.macos_desktop_shared_updates_everyday() }
    public var frequencyWeek: String { MacStrings.macos_desktop_shared_updates_everyweek() }
    public var frequencyMonth: String { MacStrings.macos_desktop_shared_updates_everymonth() }

    public var lastCheckedNever: String { MacStrings.macos_desktop_shared_updates_nevercheckedforupdates() }
    public var lastCheckedJustNow: String { MacStrings.macos_desktop_shared_app_justnow() }
    public var privacyFootnote: String { MacStrings.macos_updates_nousagedataiseversentupdate() }
    public var updateChecksNotRunningTitle: String { MacStrings.macos_updates_updatechecksarentrunningrightnow() }

    public func appHeader(version: String) -> String {
        "\(provider.appDisplayName) \(version)"
    }

    public func lastCheckedUpToDate(relative: String) -> String {
        MacStrings.macos_updates_lastcheckednoupdatefound("\(relative)")
    }

    public func lastCheckedUpdateFound(relative: String, version: String) -> String {
        MacStrings.macos_updates_lastcheckedversionfound("\(relative)", "\(version)")
    }

    public func lastCheckedStaged(relative: String, version: String) -> String {
        MacStrings.macos_updates_lastcheckedversionreadytoinstall("\(relative)", "\(version)")
    }

    public func lastCheckedFailed(relative: String) -> String {
        MacStrings.macos_updates_lastcheckedcheckfailed("\(relative)")
    }

    public func lastCheckedGeneric(relative: String) -> String {
        MacStrings.macos_updates_lastchecked("\(relative)")
    }

    public func lastCheckedRelative(checkedAt: Date, now: Date) -> String {
        if now.timeIntervalSince(checkedAt) < 60 {
            return lastCheckedJustNow
        }
        let formatter = RelativeDateTimeFormatter()
        if MacStrings.language != "en-US" { formatter.locale = Locale(identifier: MacStrings.language) }
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: checkedAt, relativeTo: now)
    }

    public func updateAvailableTitle(version: String) -> String {
        MacStrings.macos_updates_versionisavailable("\(version)")
    }

    public func updateAvailableSubtitle(version: String) -> String {
        MacStrings.macos_updates_isreadytodownload("\(provider.appDisplayName)", "\(version)")
    }

    public func updateNotificationTitle(version: String) -> String {
        MacStrings.macos_updates_isreadywhenyouare("\(provider.appDisplayName)", "\(version)")
    }

    public var updateNotificationBody: String {
        MacStrings.macos_updates_itllbeappliedthenexttime("\(provider.appDisplayName)")
    }

    public func deferredTitle(version: String) -> String {
        version.isEmpty ? MacStrings.macos_updatescopy_deferredupdate() : MacStrings.macos_updatescopy_deferredupdate2("\(version)")
    }

    public var deferredSubtitle: String { provider.deferralLine }

    public func downloadingTitle(version: String) -> String {
        MacStrings.macos_updates_downloading("\(version)")
    }

    public func downloadingSubtitle(receivedBytes: UInt64, totalBytes: UInt64?) -> String {
        byteProgress(receivedBytes: receivedBytes, totalBytes: totalBytes)
    }

    public func backgroundDownloadingTitle(version: String?) -> String {
        if let version, !version.isEmpty {
            return MacStrings.macos_updates_downloadinginthebackground("\(version)")
        }
        return MacStrings.macos_updates_downloadinganupdateinthebackground()
    }

    public func backgroundFinishingTitle(version: String?) -> String {
        if let version, !version.isEmpty {
            return MacStrings.macos_updates_finishingupinthebackground("\(version)")
        }
        return MacStrings.macos_updates_finishingupinthebackground2()
    }

    public var backgroundDownloadSubtitle: String {
        MacStrings.macos_updates_willletyouknowwhentheupdate("\(provider.appDisplayName)")
    }

    public func extractingTitle(version: String) -> String {
        MacStrings.macos_updates_downloading("\(version)")
    }

    public var extractingSubtitle: String {
        MacStrings.macos_updates_downloadcomplete("\(finalizingSuffix)")
    }

    public func readyToInstallTitle(version: String) -> String {
        MacStrings.macos_updates_readytoinstall("\(version)")
    }

    public func stagedReadyTitle(version: String) -> String {
        MacStrings.macos_updates_readytoinstallv("\(version)")
    }

    public var restartExplanation: String {
        provider.isJournal
            ? MacStrings.macos_updatescopy_yourjournalwillbeunavailablewhilethejournalap()
            : MacStrings.macos_updatescopy_intakewillpausewhilethesolstoneapprestarts()
    }

    public var readyToInstallSubtitle: String { MacStrings.macos_updates_theupdateisdownloadedandreadywhen("\(restartExplanation)") }

    public var stagedReadySubtitle: String {
        MacStrings.macos_updates_theupdateisdownloadedandwillinstall("\(provider.appDisplayName)", "\(restartExplanation)")
    }

    public func restartPromptTitle(version: String) -> String {
        MacStrings.macos_updatescopy_iswaitingtoinstall("\(provider.appDisplayName)", "\(version)")
    }

    public var restartPromptBody: String {
        MacStrings.macos_updatescopy_anupdatehasbeenreadyforafewdaysrestarttheappn("\(provider.appDisplayName)", "\(restartExplanation)")
    }

    public func installingTitle(version: String) -> String {
        MacStrings.macos_updates_installing("\(version)")
    }

    public var installingSubtitle: String {
        MacStrings.macos_updates_ishandingofftotheinstaller("\(provider.appDisplayName)")
    }

    public var actionReasonUpdatesUnavailable: String { MacStrings.macos_updates_updatesareunavailableinthisbuild() }
    public var actionReasonDownloadInProgress: String { MacStrings.macos_updates_adownloadisalreadyinprogress() }
    public var actionReasonDownloadFinishing: String { MacStrings.macos_updates_adownloadisfinishingup() }
    public var actionReasonInstallHandoff: String { MacStrings.macos_updates_aninstallhandoffisalreadyinprogress() }
    public var actionReasonUpdateChoicePending: String { MacStrings.macos_updates_anupdateneedsachoicefirst() }
    public var actionReasonChecking: String { MacStrings.macos_updates_checkingforupdates() }
    public var actionReasonExtracting: String { MacStrings.macos_updates_preparingthedownloadedupdate() }
    public var actionReasonUpdateInProgress: String { MacStrings.macos_updates_waitingfortheupdatertofinish() }

    public func byteProgress(receivedBytes: UInt64, totalBytes: UInt64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true

        let received = formatter.string(fromByteCount: Int64(receivedBytes))
        guard let totalBytes else {
            return MacStrings.macos_updates_downloaded("\(received)")
        }

        let total = formatter.string(fromByteCount: Int64(totalBytes))
        return MacStrings.macos_updates_ofdownloaded("\(received)", total)
    }
}
