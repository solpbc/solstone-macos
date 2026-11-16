import Foundation
import SolstoneCore

public enum UICopy {
    static let COMMAND_LINE_USAGE = MacStrings.macos_ui_solstoneistheapp()
    static let COMMAND_LINE_ALREADY_RUNNING = MacStrings.macos_ui_solstoneisalreadyrunning()

    enum Migration {
        static let deferChoice = MacStrings.macos_desktop_shared_copy_deferchoice()
        static let replaceOfferTitle = MacStrings.macos_desktop_shared_copy_replaceoffertitle()
        static let replaceOfferBody = MacStrings.macos_desktop_shared_copy_replaceofferbody()
        static let chooseDevice = MacStrings.macos_desktop_shared_copy_choosedevice()
        static let keepBoth = MacStrings.macos_desktop_shared_copy_keepboth()
        static let pickerTitle = MacStrings.macos_desktop_shared_copy_choosedevice()
        static let pickerEmpty = MacStrings.macos_desktop_shared_copy_pickerempty()
        static let cancel = MacStrings.macos_desktop_shared_setup_cancel()
        static func replaceConfirmTitle(_ label: String) -> String { MacStrings.macos_desktop_shared_copy_replaceconfirmtitle_argument(label) }
        static let replaceConfirmBody = MacStrings.macos_desktop_shared_copy_replaceconfirmbody()
        static let replaceDevice = MacStrings.macos_desktop_shared_copy_replacedevice()
        static let offlineTitle = MacStrings.macos_desktop_shared_app_offlinetitle()
        static let offlineBody = MacStrings.macos_desktop_shared_copy_offlinebody()
        static let tryAgain = MacStrings.macos_desktop_shared_copy_tryagain()
        static let storageUnavailableTitle = MacStrings.macos_desktop_shared_copy_storageunavailabletitle()
        static let storageUnavailableBody = MacStrings.macos_desktop_shared_copy_storageunavailablebody()
        static let technicalDetails = MacStrings.macos_desktop_shared_copy_technicaldetails()
        static let decidingTitle = MacStrings.macos_desktop_shared_copy_decidingtitle()
        static let decisionUnknownTitle = MacStrings.macos_desktop_shared_copy_decisionunknowntitle()
        static let decisionUnknownBody = MacStrings.macos_desktop_shared_copy_decisionunknownbody()
        static let checkAgain = MacStrings.macos_desktop_shared_copy_checkagain()
        static let listUnavailableTitle = MacStrings.macos_desktop_shared_copy_listunavailabletitle()
        static let listUnavailableBody = MacStrings.macos_desktop_shared_copy_listunavailablebody()
        static let targetMissingTitle = MacStrings.macos_desktop_shared_copy_targetmissingtitle()
        static let targetMissingBody = MacStrings.macos_desktop_shared_copy_targetmissingbody()
        static let decisionRefusedTitle = MacStrings.macos_desktop_shared_copy_decisionrefusedtitle()
        static let decisionRefusedBody = MacStrings.macos_desktop_shared_copy_decisionrefusedbody()
        static let replaceConfirmTitleFallback = MacStrings.macos_desktop_shared_copy_replaceconfirmtitlefallback()
    }

    public static let SOURCES_TITLE = MacStrings.macos_desktop_shared_app_sourcestitle()
    enum Terminal {
        static let sourceTitle = MacStrings.macos_ui_terminal()
        static let sourceHelp = MacStrings.macos_ui_takesinyourtmux()
        static let moveTitle = MacStrings.macos_ui_movesolstonefortmux()
        static let moveBody = MacStrings.macos_ui_thismovessolstonefor()
        static let moveBodyUnpaired = MacStrings.macos_ui_thisappisnt()
        static let waitingForPairing = MacStrings.macos_ui_pairthisappwith()
        static let waitingForMark = MacStrings.macos_copy_journalmarkconfirmaction()
        static let moveConfirm = MacStrings.macos_ui_moveit()
        static let moveCancel = MacStrings.macos_desktop_shared_copy_deferchoice()
        static let oldAppWaiting = MacStrings.macos_ui_solstonefortmuxis()
        static let plistNotOurs = MacStrings.macos_ui_thesolstonefortmux()
        static let oldAppStillRunning = MacStrings.macos_ui_solstonefortmuxis2()
        static let oldSpoolUnreadable = MacStrings.macos_ui_somethingsolstonefortmux()

        static func unreadableRecord(_ path: String) -> String {
            MacStrings.macos_ui_therecordofmoving("\(path)")
        }

        static func unsendable(_ count: Int) -> String { MacStrings.macos_ui_cantbesent_native_plural(count) }

        static func moveLine(_ record: TerminalTakeoverRecord) -> [String] {
            var lines: [String] = []
            if record.phase < .done { lines.append(MacStrings.macos_ui_movingsolstonefortmux()) }
            switch record.continuity {
            case .newStream(let reason, let attention):
                lines.append(MacStrings.macos_ui_newterminalhistoryfrom("\(reason)"))
                if attention { lines.append(MacStrings.macos_ui_thisneedsattentionplease()) }
            case .continued, nil: break
            }
            if let answer = record.lastAnswer { lines.append(MacStrings.macos_ui_waiting("\(answer)")) }
            if record.heldCount != 0 {
                lines.append(MacStrings.macos_terminal_heldsegments(record.heldCount))
            }
            lines.append(contentsOf: record.problems.map { MacStrings.macos_ui_problem("\($0)") })
            return lines
        }

        @MainActor
        static func statusLine(_ state: TerminalSource.State) -> String? {
            switch state {
            case .off: return nil
            case .running: return MacStrings.macos_ui_terminalrunning()
            case .paused: return MacStrings.macos_ui_terminalpaused()
            case .tmuxNotFound: return MacStrings.macos_ui_terminaltmuxisnt()
            case .oldAppInstalled: return oldAppWaiting
            case .restarting: return MacStrings.macos_ui_terminalstoppedbyan()
            }
        }
    }

    enum Obsidian {
        static let TITLE = MacStrings.macos_ui_obsidian()
        static let EXPLAINER = MacStrings.macos_ui_thesolstoneapptakes()
        static let FOUND_VAULTS = MacStrings.macos_ui_vaultsonthismac()
        static let CHOOSE_FOLDER = MacStrings.macos_screenshot_chooseafolder()
        static let PANEL_PROMPT = MacStrings.macos_ui_choose()
        static let PANEL_MESSAGE = MacStrings.macos_ui_chooseyourobsidianvault()
        static let TURN_OFF_HELP = MacStrings.macos_ui_turningthisoffremoves()
        static let TURN_OFF = MacStrings.macos_ui_turnoff()
        static let CONTINUE = MacStrings.macos_desktop_shared_copy_setupcontinue()
        static let CANCEL = MacStrings.macos_desktop_shared_setup_cancel()
        static let REFUSED_NOT_A_VAULT = MacStrings.macos_ui_thatfolderisnt()
        static let REFUSED_UNUSABLE_NAME = MacStrings.macos_ui_thisfoldersname()
        static let REFUSED_UNREADABLE = MacStrings.macos_ui_thesolstoneappcouldn()

        static func stateLine(_ phase: ObsidianVaultSource.Phase, vaultName: String?) -> String {
            switch phase {
            case .off: return TITLE
            case .on:
                if let vaultName { return MacStrings.macos_ui_obsidianison("\(vaultName)") }
                return MacStrings.macos_ui_obsidianison2()
            case .paused: return MacStrings.macos_ui_obsidianispausedyour()
            case .waitingForJournalUpdate: return MacStrings.macos_ui_waitingforajournal()
            case .needsAttention: return MacStrings.macos_ui_obsidianneedsattention()
            }
        }

        static func attentionLine(vaultUnreadable: Bool, partUnreadable: Bool) -> String {
            if vaultUnreadable {
                return MacStrings.macos_ui_thesolstoneappcan()
            }
            if partUnreadable {
                return MacStrings.macos_ui_partofthisvault()
            }
            return MacStrings.macos_ui_somenotescouldnt()
        }

        static func lastChecked(_ time: String) -> String { MacStrings.macos_updates_lastchecked("\(time)") }

        static func waiting(_ count: Int) -> String { MacStrings.macos_ui_waitingtosync_native(MacStrings.number(count)) }

        static func progress(sent: Int, found: Int) -> String { MacStrings.macos_ui_ofnotesinyour(MacStrings.number(sent), MacStrings.number(found)) }

        static func notOnThisMac(_ count: Int) -> String { MacStrings.macos_ui_notonthismac_native(MacStrings.number(count)) }

        static func tooLarge(_ count: Int) -> String { MacStrings.macos_ui_over4mbnot_native(MacStrings.number(count)) }

        static func alreadySynced(vault: String, device: String?, date: String?) -> String {
            let from = device.map { MacStrings.macos_screenshot_from("\($0)") } ?? MacStrings.macos_ui_fromanotherdevice()
            let when = date.map { MacStrings.macos_ui_lastupdated("\($0)") } ?? ""
            return MacStrings.macos_ui_yourjournalalreadyhas("\(vault)", "\(from)", "\(when)")
        }
    }

    // Audio health
    public static let AUDIO_SOURCE_SYSTEM = MacStrings.macos_uicopy_computersound()
    public static let AUDIO_SOURCE_MICROPHONE = MacStrings.macos_copy_audiosourcemicrophone()
    /// Owner-facing audio health, naming each source. Nil when nothing needs saying.
    public static func audioIssue(recovering: [String], recovered: [String]) -> String? {
        func list(_ names: [String]) -> String {
            let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if MacStrings.language != "en-US" {
                let formatter = ListFormatter()
                formatter.locale = Locale(identifier: MacStrings.language)
                return formatter.string(from: unique) ?? unique.joined(separator: ", ")
            }
            return unique.count <= 1 ? (unique.first ?? "") : MacStrings.macos_list_andpair(unique.dropLast().joined(separator: ", "), unique.last!)
        }
        if !recovering.isEmpty {
            return MacStrings.macos_audio_recovering(Set(recovering).count, list(recovering))
        }
        if !recovered.isEmpty {
            return MacStrings.macos_audio_recovered(Set(recovered).count, list(recovered))
        }
        return nil
    }

    // Microphones
    public static let MICROPHONES_LIST_CAPTION = MacStrings.macos_copy_microphoneslistcaption()
    public static let MICROPHONE_MODE_WHEN_IN_USE = MacStrings.macos_copy_microphonemodewheninuse()
    public static let MICROPHONE_MODE_ALWAYS = MacStrings.macos_ui_always()
    public static let MICROPHONE_MODE_OFF = MacStrings.macos_desktop_shared_app_microphonemodeoff()
    public static let MICROPHONE_MODE_HELP = MacStrings.macos_copy_microphonemodehelp()
    public static let MICROPHONE_ALWAYS_CALL_MODE = MacStrings.macos_copy_microphonealwayscallmode()
    public static let MICROPHONE_NEEDS_CHOICE = MacStrings.macos_copy_microphoneneedschoice()
    public static let MICROPHONE_INPUTS_CHANGED = MacStrings.macos_copy_microphoneinputschanged()
    public static let MICROPHONE_LAYOUT_UNAVAILABLE = MacStrings.macos_copy_microphonelayoutunavailable()
    public static let MICROPHONE_INPUT_RETRY = MacStrings.macos_desktop_shared_copy_tryagain()
    public static func microphoneInputTitle(number: Int, label: String?) -> String {
        if let label, !label.isEmpty {
            return MacStrings.macos_copy_input("\(number)", "\(label)")
        }
        return MacStrings.macos_copy_input2("\(number)")
    }
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    public static let SOURCES_HELP = MacStrings.macos_copy_sourceshelp()
    public static let SOURCES_NONE = MacStrings.macos_copy_sourcesnone()
    public static let SOURCES_NONE_REASON = MacStrings.macos_copy_sourcesnonereason()
    public static let SOURCES_BROWSER_PAGES = MacStrings.macos_desktop_shared_copy_sourcesbrowserpages()

    // Group & store
    public static let SOURCES_BROWSERS_GROUP_TITLE = MacStrings.macos_ui_browsers()
    public static let SOURCES_BROWSERS_NO_HISTORY = MacStrings.macos_copy_sourcesbrowsersnohistory()
    public static let SOURCES_BROWSERS_STORES_CONFIGURED = MacStrings.macos_ui_addthesolstoneextension()
    public static func sourcesBrowserAddAction(browser: String) -> String { MacStrings.macos_copy_addto("\(browser)") }
    public static func sourcesBrowserLaunchFailure(browser: String) -> String { MacStrings.macos_copy_couldntopenthestorepagein("\(browser)") }

    // Rows
    public static func sourcesBrowserRowLabel(browser: String, profileCount: Int) -> String {
        profileCount > 1 ? MacStrings.macos_copy_profiles_native("\(browser)", "\(profileCount)") : browser
    }
    public static let SOURCES_BROWSER_CONNECTED_NOW = MacStrings.macos_desktop_shared_copy_sourcesbrowserconnectednow()
    public static func sourcesBrowserLastSeen(_ relative: String) -> String { MacStrings.macos_copy_lastseen("\(relative)") }
    public static func sourcesBrowserConnectedLastPage(_ relative: String) -> String { MacStrings.macos_copy_connectednowlastpage("\(relative)") }
    public static func sourcesBrowserLastPage(_ relative: String) -> String { MacStrings.macos_copy_lastpage("\(relative)") }
    public static let SOURCES_BROWSER_NEEDS_EXT_UPDATE = MacStrings.macos_copy_sourcesbrowserneedsextupdate()
    public static let SOURCES_BROWSER_NEEDS_APP_UPDATE = MacStrings.macos_copy_sourcesbrowserneedsappupdate()
    public static let SOURCES_BROWSER_ROW_NOT_CONNECTED = MacStrings.macos_uicopy_notconnectedyet()
    public static let SOURCES_BROWSER_ROW_CANT_FIND_APP = MacStrings.macos_uicopy_cantfindthesolstoneapp()
    public static let SOURCES_BROWSER_ROW_SAFARI_OFF = MacStrings.macos_uicopy_turnedoffinsafari()

    // State lines
    public static let SOURCES_BROWSER_INTAKE_OFF = MacStrings.macos_copy_sourcesbrowserintakeoff()
    public static let SOURCES_BROWSER_DRAINING = MacStrings.macos_copy_sourcesbrowserdraining()
    public static let SOURCES_BROWSER_NEWER_EXTENSION = MacStrings.macos_copy_sourcesbrowsernewerextension()
    public static let SOURCES_BROWSER_FULL = MacStrings.macos_copy_sourcesbrowserfull()
    public static let SOURCES_BROWSER_STALE = MacStrings.macos_copy_sourcesbrowserstale()
    public static let SOURCES_BROWSER_CANNOT_START = MacStrings.macos_copy_sourcesbrowsercannotstart()
    public static let SOURCES_BROWSER_UNKNOWN = MacStrings.macos_copy_sourcesbrowserunknown()
    public static let SOURCES_BROWSER_HELD = MacStrings.macos_desktop_shared_copy_sourcesbrowserheld()
    public static let SOURCES_BROWSER_LOST_AND_HELD = MacStrings.macos_copy_sourcesbrowserlostandheld()
    public static let SOURCES_BROWSER_PAUSED = MacStrings.macos_copy_sourcesbrowserpaused()
    public static let SOURCES_BROWSER_DELIVERY_FAILED = MacStrings.macos_copy_sourcesbrowserdeliveryfailed()
    public static let SOURCES_BROWSER_REGISTRATION_BROKEN = MacStrings.macos_copy_sourcesbrowserregistrationbroken()
    public static let SOURCES_BROWSER_DISCARD = MacStrings.macos_desktop_shared_copy_sourcesbrowserdiscard()
    public static let SOURCES_BROWSER_DISCARD_CONFIRM = MacStrings.macos_desktop_shared_copy_sourcesbrowserdiscardconfirm()
    public static let SOURCES_BROWSER_DISCARD_COMMIT = MacStrings.macos_desktop_shared_copy_sourcesbrowserdiscardcommit()
    public static let SOURCES_BROWSER_DISCARDED = MacStrings.macos_ui_discarded()
    public static let SOURCES_BROWSER_DISCARD_FAILED = MacStrings.macos_copy_sourcesbrowserdiscardfailed()

    // Repair
    public static let SOURCES_BROWSER_REPAIR_ACTION = MacStrings.macos_ui_repair()
    public static let SOURCES_BROWSER_REPAIRED = MacStrings.macos_ui_repaired()
    public static func sourcesBrowserRepairFailed(reason: String) -> String { MacStrings.macos_copy_couldntrepair("\(reason)") }
    public static func browserSetupReason(_ code: String?) -> String {
        switch code {
        case "listener_down": return MacStrings.macos_copy_theappisntavailable()
        case "endpoint_collision": return MacStrings.macos_copy_theappsconnectioncouldntbe()
        case "helper_path_not_bundled", "unsafe_helper_path", "invalid_contract", "invalid_template":
            return MacStrings.macos_copy_theappsfilescouldntbe()
        case "manifest_missing", "manifest_change_required", "unsafe_registration_directory", "unsafe_manifest", "manifest_verification_failed", "registration_io":
            return MacStrings.macos_copy_thebrowsersetupcouldntbechanged()
        default: return MacStrings.macos_copy_thesetupcouldntbechecked()
        }
    }
    public static let SOURCES_BROWSER_FOOTNOTE = MacStrings.macos_ui_thesolstoneextensionworks()
    public static let SOURCES_BROWSER_SAFARI_SETTINGS_ACTION = MacStrings.macos_copy_sourcesbrowsersafarisettingsaction()
    public static let SOURCES_BROWSER_SAFARI_UNAVAILABLE = MacStrings.macos_copy_sourcesbrowsersafariunavailable()
    public static let SOURCES_BROWSER_SAFARI_ON = MacStrings.macos_copy_sourcesbrowsersafarion()
    public static let SOURCES_BROWSER_SAFARI_OFF = MacStrings.macos_copy_sourcesbrowsersafarioff()
    public static let SOURCES_BROWSER_SAFARI_SETTINGS_FAILED = MacStrings.macos_copy_sourcesbrowsersafarisettingsfailed()

    // Menu row
    public static func menubarBrowsersLive(_ brands: String) -> String { MacStrings.macos_copy_browsers("\(brands)") }
    public static let MENUBAR_BROWSERS_NONE_CONNECTED = MacStrings.macos_desktop_shared_copy_menubarbrowsersnoneconnected()
    public static let MENUBAR_BROWSERS_NONE_YET = MacStrings.macos_copy_menubarbrowsersnoneyet()
    public static let MENUBAR_BROWSERS_OFF = MacStrings.macos_desktop_shared_copy_menubarbrowsersoff()
    public static let MENUBAR_BROWSERS_PAUSED = MacStrings.macos_copy_menubarbrowserspaused()

    // Headlines
    public static let SOURCES_BROWSER_HEADLINE_READY = MacStrings.macos_copy_sourcesbrowserheadlineready()
    public static let SOURCES_BROWSER_HEADLINE_WAITING = MacStrings.macos_copy_sourcesbrowserheadlinewaiting()

    // Legend footnote
    public static let SETTINGS_HELP_BROWSER_FOOTNOTE = MacStrings.macos_ui_thesolstoneextensionshows()

    // Diagnostics labels
    public static let DIAGNOSTICS_BROWSER_PAGES_LABEL = MacStrings.macos_desktop_shared_copy_sourcesbrowserpages()
    public static let DIAGNOSTICS_BROWSERS_SEEN_LABEL = MacStrings.macos_copy_diagnosticsbrowsersseenlabel()
    public static let DIAGNOSTICS_BROWSER_SETUP_LABEL = MacStrings.macos_copy_diagnosticsbrowsersetuplabel()
#else
    public static let SOURCES_HELP = MacStrings.macos_copy_sourceshelp()
    public static let SOURCES_NONE = MacStrings.macos_copy_sourcesnone2()
    public static let SOURCES_NONE_REASON = MacStrings.macos_copy_sourcesnonereason2()
    public static let SOURCES_BROWSER_SAFARI_UNAVAILABLE = MacStrings.macos_copy_sourcesbrowsersafariunavailable()
#endif

    public static let CREATE_JOURNAL_ON_THIS_MAC = MacStrings.macos_copy_createjournalonthismac()

    // Native Setup
    public static let SETUP_JOURNAL_STILL_BEING_SET_UP = MacStrings.macos_copy_setupjournalstillbeingsetup()
    public static let SETUP_OPENING_YOUR_JOURNAL = MacStrings.macos_copy_setupopeningyourjournal()
    public static let SETUP_OPEN_THE_JOURNAL_APP_TO_CONTINUE = MacStrings.macos_copy_setupopenthejournalapptocontinue()
    public static let SETUP_COULDNT_INSTALL_JOURNAL_APP = MacStrings.macos_copy_setupcouldntinstalljournalapp()
    public static let JOURNAL_APP_DOWNLOAD = MacStrings.macos_copy_journalappdownload()
    public static let SETUP_COULDNT_REACH_YOUR_JOURNAL = MacStrings.macos_copy_setupcouldntreachyourjournal()
    public static let SETUP_COULDNT_FINISH = MacStrings.macos_copy_setupcouldntfinish()
    public static let SETUP_COULDNT_SAVE_PROGRESS = MacStrings.macos_copy_journalmarkunverifiedbody()
    public static let SETUP_TRY_AGAIN = MacStrings.macos_desktop_shared_copy_tryagain()
    public static let SETUP_MICROPHONE = MacStrings.macos_copy_accessibilityexplanation()
    public static let SETUP_MICROPHONE_EXPLAINER = MacStrings.macos_copy_journalmarkmismatchtitle()
    public static let SETUP_TURN_ON_MICROPHONE = MacStrings.macos_copy_journalmarkmismatchbody()
    public static let SETUP_NOT_NOW = MacStrings.macos_desktop_shared_copy_deferchoice()
    public static let SETUP_CONTINUE = MacStrings.macos_desktop_shared_copy_setupcontinue()
    public static let SETUP_SCREEN_AND_COMPUTER_SOUND = MacStrings.macos_copy_setupscreenandcomputersound()
    public static let SETUP_SCREEN_EXPLAINER = MacStrings.macos_copy_setupscreenexplainer()
    public static let SETUP_SCREEN_STORAGE = MacStrings.macos_copy_setupscreenstorage()
    public static let SETUP_SCREEN_LEFT_OUT = MacStrings.macos_copy_setupscreenleftout()
    public static let SETUP_TURN_ON_SCREEN = MacStrings.macos_copy_setupturnonscreen()
    public static let SETUP_SCREEN_SHOWS_HERE = MacStrings.macos_copy_setupscreenshowshere()
    public static let SETUP_CONNECT_TO_YOUR_JOURNAL = MacStrings.macos_copy_setupconnecttoyourjournal()
    public static let SETUP_CONNECTING_TO_YOUR_JOURNAL = MacStrings.macos_app_setupconnectingtoyourjournal()
    public static let SETUP_COULDNT_VERIFY_MARK = MacStrings.macos_copy_setupcouldntverifymark()
    public static let SETUP_ACKNOWLEDGEMENT_FAILED = MacStrings.macos_copy_setupacknowledgementfailed()
    public static let SETUP_OPEN_YOUR_JOURNAL = MacStrings.macos_desktop_shared_copy_setupopenyourjournal()
    public static let SETUP_FINISH = MacStrings.macos_ui_finish()
    public static let SETUP_CONNECTED_TO_YOUR_JOURNAL = MacStrings.macos_desktop_shared_copy_setupconnectedtoyourjournal()
    public static let SETUP_WINDOW_TITLE = MacStrings.macos_desktop_shared_copy_setupwindowtitle()
    public static let SETUP_APP_LABEL = MacStrings.macos_desktop_shared_copy_setupapplabel()
    public static let SETUP_WELCOME_HEADLINE = MacStrings.macos_copy_setupwelcomeheadline()
    public static let SETUP_WELCOME_BODY_1 = MacStrings.macos_desktop_shared_about_setupwelcomebody1()
    public static let SETUP_WELCOME_BODY_2 = MacStrings.macos_desktop_shared_copy_setupwelcomebody2()
    public static let SETUP_JOURNAL_CARD_HEADING = MacStrings.macos_desktop_shared_copy_setupjournalcardheading()
    public static let SETUP_JOURNAL_CARD_BODY = MacStrings.macos_copy_setupjournalcardbody()
    public static let SETUP_CREATE_JOURNAL_CHOICE = MacStrings.macos_copy_setupcreatejournalchoice()
    public static let SETUP_CONNECT_JOURNAL_CHOICE = MacStrings.macos_copy_setupconnectjournalchoice()
    public static let SETUP_MICROPHONE_HEADLINE = MacStrings.macos_desktop_shared_copy_setupmicrophoneheadline()
    public static let SETUP_SCREEN_HEADLINE = MacStrings.macos_copy_setupscreenheadline()
    public static let SETUP_MICROPHONE_STATUS_ON = MacStrings.macos_copy_setupmicrophonestatuson()
    public static let SETUP_MICROPHONE_STATUS_PAUSED = MacStrings.macos_copy_setupmicrophonestatuspaused()
    public static let SETUP_MICROPHONE_STATUS_OFF = MacStrings.macos_copy_setupmicrophonestatusoff()
    public static let SETUP_SCREEN_STATUS_ON = MacStrings.macos_copy_setupscreenstatuson()
    public static let SETUP_SCREEN_STATUS_PAUSED = MacStrings.macos_copy_setupscreenstatuspaused()
    public static let SETUP_SCREEN_STATUS_OFF = MacStrings.macos_copy_setupscreenstatusoff()
    public static let SETUP_SCREEN_FRAME_CAPTION = MacStrings.macos_desktop_shared_copy_setupscreenframecaption()
    public static func connectedTo(mark: String) -> String {
        MacStrings.macos_copy_connectedto("\(mark)")
    }
    public static let SETUP_CONNECTED_EXPLANATION = MacStrings.macos_copy_setupconnectedexplanation()
    public static let SETUP_BACK = MacStrings.macos_desktop_shared_copy_setupback()
    public static func setupStepProgress(n: Int, m: Int) -> String {
        MacStrings.macos_copy_stepof("\(n)", "\(m)")
    }

    public static let SOURCES_SEGMENTS_EXPLAINER = MacStrings.macos_copy_sourcessegmentsexplainer()
    public static let SOURCES_MICROPHONE = MacStrings.macos_copy_accessibilityexplanation()
    public static let SOURCES_SCREEN = MacStrings.macos_copy_setupscreenandcomputersound()
    public static let SOURCES_OFF = MacStrings.macos_desktop_shared_app_microphonemodeoff()
    public static let SOURCES_STARTING = MacStrings.macos_ui_starting()
    public static let SOURCES_OPEN_ACTION = MacStrings.macos_copy_sourcesopenaction()
    public static let PERMISSIONS_OPEN_ACTION = MacStrings.macos_copy_permissionsopenaction()

    // Selected, but macOS hasn't granted either one.
    public static let SOURCES_UNAVAILABLE = MacStrings.macos_copy_sourcesunavailable()
    public static let SOURCES_UNAVAILABLE_REASON = MacStrings.macos_copy_sourcesunavailablereason()
    public static let SOURCES_NONE_GRANTED = MacStrings.macos_copy_sourcesnonegranted()
    public static let SOURCES_GRANT_OR_CHANGE = MacStrings.macos_copy_sourcesgrantorchange()

    // Per-source notices, shown beside a session that is running on the other source.
    public static let SOURCES_MIC_DENIED = MacStrings.macos_uicopy_microphonepermissionnotgrantedscreenandcomput()
    public static let SOURCES_SCREEN_DENIED = MacStrings.macos_copy_sourcesscreendenied()
    public static let SOURCES_MIC_UNAVAILABLE = MacStrings.macos_uicopy_microphoneunavailablescreenandcomputersoundar()
    public static let SOURCES_SCREEN_UNAVAILABLE = MacStrings.macos_uicopy_screenandcomputersoundunavailablemicrophoneis()

    public static let SOURCES_RESTART_READY = MacStrings.macos_copy_sourcesrestartready()
    public static let SOURCES_RESTART = MacStrings.macos_copy_sourcesrestart()

    public static func sourceNames(_ sources: CaptureSources) -> String {
        switch (sources.contains(.microphone), sources.contains(.screen)) {
        case (true, true): return MacStrings.macos_uicopy_microphonescreenandcomputersound()
        case (true, false): return SOURCES_MICROPHONE
        case (false, true): return SOURCES_SCREEN
        case (false, false): return SOURCES_OFF
        }
    }

    public static func sourceStatus(_ sources: CaptureSources, isPaused: Bool = false) -> String {
        guard !sources.isEmpty else { return SOURCES_OFF }
        return isPaused ? MacStrings.macos_sources_statuspaused(sourceNames(sources)) : MacStrings.macos_sources_statuson(sourceNames(sources))
    }

    public static let JOURNAL_WINDOW_TITLE = MacStrings.macos_desktop_shared_copy_setupjournalcardheading()
    public static let JOURNAL_WINDOW_LOADING = MacStrings.macos_copy_setupopeningyourjournal()
    public static let JOURNAL_WINDOW_ERROR = MacStrings.macos_copy_journalwindowerror()
    public static let JOURNAL_LINK_INVALID_TITLE = MacStrings.macos_uicopy_thisjournallinkisntvalid()
    public static let JOURNAL_LINK_INVALID_BODY = MacStrings.macos_uicopy_copythefulllinkfromyourchatandopenitagain()
    public static let JOURNAL_WINDOW_RETRY = MacStrings.macos_desktop_shared_copy_tryagain()
    public static let JOURNAL_PANEL_OK = MacStrings.macos_desktop_shared_settings_severity()
    public static let JOURNAL_PANEL_CANCEL = MacStrings.macos_desktop_shared_setup_cancel()
    public static let JOURNAL_MODE_THIS_MAC_LABEL = MacStrings.macos_copy_journalmodethismaclabel()
    public static let JOURNAL_MODE_ANOTHER_MACHINE_LABEL = MacStrings.macos_copy_journalmodeanothermachinelabel()
    public static let PAIRING_LINK_PLACEHOLDER = MacStrings.macos_setup_pairinglinkplaceholder()
    public static let PAIRING_NOTENTITLED_RECOVERY = MacStrings.macos_copy_pairingnotentitledrecovery()
    public static let PAIRING_DISCONNECT_CONFIRM = MacStrings.macos_copy_pairingdisconnectconfirm()
    public static let PAIRING_SAVE_FAILED = MacStrings.macos_copy_pairingsavefailed()
    public static let SAME_MACHINE_LINK_ALREADY_LINKED = MacStrings.macos_copy_samemachinelinkalreadylinked()
    public static let LOCAL_JOURNAL_NOT_YOURS = MacStrings.macos_ui_thejournalrunningon()
    public static let SAME_MACHINE_LINK_UNREACHABLE = MacStrings.macos_copy_samemachinelinkunreachable()
    public static let JOURNAL_LINK_FAILED = MacStrings.macos_ui_couldntopenyour()
    public static let SAME_MACHINE_LINK_REFUSED = MacStrings.macos_copy_samemachinelinkrefused()
    public static let SAME_MACHINE_LINK_UNEXPECTED = MacStrings.macos_copy_samemachinelinkunexpected()
    public static let SAME_MACHINE_LINK_UNFINISHED = MacStrings.macos_copy_samemachinelinkunfinished()
    public static let SAME_MACHINE_LINK_CREDENTIALS_UNAVAILABLE = MacStrings.macos_copy_samemachinelinkcredentialsunavailable()
    public static let SAME_MACHINE_LINK_OTHER_JOURNAL = MacStrings.macos_copy_samemachinelinkotherjournal()
    public static func relinkNeedsPairingLink(address: String?) -> String {
        guard let address else {
            return MacStrings.macos_copy_linkingagaintakesapairinglinkget()
        }
        return MacStrings.macos_copy_thismacissetupfora("\(address)")
    }
    public static let JOURNAL_MARK_CONFIRM_QUESTION = MacStrings.macos_desktop_shared_copy_journalmarkconfirmquestion()
    public static let JOURNAL_MARK_CONFIRM_SUBTEXT = MacStrings.macos_copy_journalmarkconfirmsubtext()
    public static let JOURNAL_MARK_CONFIRM_BUTTON = MacStrings.macos_desktop_shared_copy_journalmarkconfirmbutton()
    public static let JOURNAL_MARK_MISMATCH_BUTTON = MacStrings.macos_desktop_shared_copy_journalmarkmismatchbutton()
    public static let JOURNAL_MARK_UNVERIFIED_TITLE = MacStrings.macos_desktop_shared_copy_journalmarkunverifiedtitle()
    public static let JOURNAL_MARK_UNVERIFIED_BODY = MacStrings.macos_ui_thecheckofyour()
    public static let JOURNAL_MARK_UNVERIFIED_CONTINUE_BUTTON = MacStrings.macos_desktop_shared_copy_journalmarkunverifiedcontinuebutton()
    public static let JOURNAL_MARK_UNVERIFIED_CANCEL_BUTTON = MacStrings.macos_desktop_shared_copy_journalmarkunverifiedcancelbutton()
    public static let JOURNAL_MARK_MISMATCH_TITLE = MacStrings.macos_desktop_shared_app_notpaired()
    public static let JOURNAL_MARK_MISMATCH_BODY = MacStrings.macos_ui_nothingthismachas()
    public static let JOURNAL_MARK_MISMATCH_FRESH_LINK = MacStrings.macos_copy_journalmarkmismatchfreshlink()
    public static let JOURNAL_MARK_SWITCH_NOT_CHANGED_TITLE = MacStrings.macos_ui_notchanged()
    public static let UNKNOWN_JOURNAL_ROW_RELAY = MacStrings.macos_ui_unknownjournalseenthrough()
    public static let UNKNOWN_JOURNAL_VIEW_DETAILS = MacStrings.macos_ui_viewdetails()
    public static let UNKNOWN_JOURNAL_HEADING = MacStrings.macos_ui_somethingansweredinsteadof()
    public static let UNKNOWN_JOURNAL_BODY_RELAY = MacStrings.macos_ui_somethingansweredthismac()
    public static let UNKNOWN_JOURNAL_LABEL_WHAT_ANSWERED = MacStrings.macos_ui_whatanswered()
    public static let UNKNOWN_JOURNAL_LABEL_YOUR_JOURNAL = MacStrings.macos_desktop_shared_copy_setupjournalcardheading()
    public static let UNKNOWN_JOURNAL_CAPTION_CLAIMED = MacStrings.macos_ui_claimednotverified()
    public static let UNKNOWN_JOURNAL_CAPTION_NOT_PRESENTED = MacStrings.macos_ui_noidentitypresented()
    public static func unknownJournalRow(address: String) -> String {
        MacStrings.macos_ui_unknownjournalseenat("\(address)")
    }
    public static func unknownJournalBody(address: String) -> String {
        MacStrings.macos_ui_somethingansweredthismac2("\(address)")
    }
    public static let JOURNAL_MARK_SWITCH_NOT_CHANGED_BODY = MacStrings.macos_ui_yourcurrentpairingstays()
    public static let JOURNAL_MARK_MISMATCH_SUPPORT = MacStrings.macos_copy_journalmarkmismatchsupport()
    public static let SETTINGS_PREREQ_PERMISSIONS = MacStrings.macos_copy_settingsprereqpermissions()
    public static let SETTINGS_NEXT_CONNECT_JOURNAL = MacStrings.macos_copy_settingsnextconnectjournal()
    public static let SETTINGS_NEXT_CHECK_STATUS = MacStrings.macos_copy_settingsnextcheckstatus()
    public static let SETTINGS_LOCAL_JOURNAL_FOUND_EXISTING = MacStrings.macos_copy_settingslocaljournalfoundexisting()
    public static let SETTINGS_LOCAL_JOURNAL_INSTALL_EXISTING = MacStrings.macos_copy_settingslocaljournalinstallexisting()
    public static let SETTINGS_LOCAL_JOURNAL_OPEN_EXISTING = MacStrings.macos_copy_settingslocaljournalopenexisting()
    public static let SETTINGS_JOURNAL_OPEN = MacStrings.macos_desktop_shared_copy_settingsjournalopen()
    public static let SETTINGS_TAB_DONE_A11Y = MacStrings.macos_ui_configured()
    public static let SETTINGS_TAB_ATTENTION_A11Y = MacStrings.macos_desktop_shared_copy_settingstabattentiona11y()
    public static let SETTINGS_TAB_UPDATES_DONE_A11Y = MacStrings.macos_desktop_shared_copy_settingstabupdatesdonea11y()
    public static let SETTINGS_ATTENTION_PERMISSIONS = MacStrings.macos_copy_settingsattentionpermissions()
    public static let SETTINGS_ATTENTION_PRIVATE_WINDOWS = MacStrings.macos_copy_settingsattentionprivatewindows()
    public static func privateWindowsChecking(macOSMajor: Int) -> String {
        MacStrings.macos_uicopy_checkingfor("\(Websites.accessibilityName(macOSMajor: macOSMajor))")
    }
    public static let SETTINGS_ATTENTION_JOURNAL = MacStrings.macos_copy_settingsattentionjournal()
    public static let SETTINGS_ATTENTION_UPDATE_AVAILABLE = MacStrings.macos_copy_settingsattentionupdateavailable()
    public static let SETTINGS_ATTENTION_UPDATE_CHECK_FAILED = MacStrings.macos_copy_settingsattentionupdatecheckfailed()
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    public static let MENUBAR_SOURCES_OFF_OPEN_SETTINGS = MacStrings.macos_copy_menubarsourcesoffopensettings()
#else
    public static let MENUBAR_SOURCES_OFF_OPEN_SETTINGS = MacStrings.macos_copy_menubarsourcesoffopensettings2()
#endif
    public static let MENUBAR_NO_SOURCE_OPEN_SETTINGS = MacStrings.macos_copy_menubarnosourceopensettings()
    public static let MENUBAR_OBSERVING_CONNECTED = MacStrings.macos_copy_menubarobservingconnected()
    public static let MENUBAR_OBSERVATION_WEDGE_OPEN_SETTINGS = MacStrings.macos_copy_menubarobservationwedgeopensettings()
    public static let MENUBAR_OBSERVING_OFFLINE_SAVED_LOCALLY = MacStrings.macos_copy_menubarobservingofflinesavedlocally()
    public static let MENUBAR_LOCAL_ONLY_SETUP_JOURNAL = MacStrings.macos_copy_menubarlocalonlysetupjournal()
    public static let MENUBAR_SYNC_PAUSED = MacStrings.macos_copy_menubarsyncpaused()
    public static let MENUBAR_SAFARI_KEPT_OUT = MacStrings.macos_uicopy_safarileftoutofscreen()
    public static let MENUBAR_SITE_SCREEN_HELD = MacStrings.macos_ui_screenpausedforwebsites()
    public static let MENUBAR_A11Y_SAFARI_KEPT_OUT = MacStrings.macos_uicopy_safariisleftoutofwhatthesolstoneapptakesinfro()

    public static func formattedBrowserList(_ browsers: [PrivateBrowser]) -> String {
        let order: [PrivateBrowser] = [.safari, .chrome, .edge, .brave]
        let present = order.filter { browsers.contains($0) }
        let names = present.compactMap { browser -> String? in
            switch browser {
            case .safari: return MacStrings.macos_settings_safari()
            case .chrome: return MacStrings.macos_uicopy_chrome()
            case .edge: return MacStrings.macos_uicopy_edge()
            case .brave: return MacStrings.macos_uicopy_brave()
            default: return nil
            }
        }
        if MacStrings.language != "en-US" {
            let formatter = ListFormatter()
            formatter.locale = Locale(identifier: MacStrings.language)
            return formatter.string(from: names) ?? names.joined(separator: ", ")
        }
        if names.count <= 1 {
            return names.first ?? ""
        } else if names.count == 2 {
            return MacStrings.macos_uicopy_and("\(names[0])", "\(names[1])")
        } else {
            let leading = names.dropLast().joined(separator: ", ")
            return MacStrings.macos_uicopy_and("\(leading)", "\(names.last!)")
        }
    }

    public static func browserKeptOutMenuTitle(browsers: [PrivateBrowser]) -> String {
        let names = formattedBrowserList(browsers)
        return MacStrings.macos_uicopy_leftoutofscreen("\(names)")
    }

    public static func browserKeptOutAccessibilityLabel(browsers: [PrivateBrowser]) -> String {
        let order: [PrivateBrowser] = [.safari, .chrome, .edge, .brave]
        let present = order.filter { browsers.contains($0) }
        let names = formattedBrowserList(present)
        return MacStrings.macos_browser_leftoutspoken(present.count, names)
    }
    public static let MENUBAR_STARTING = MacStrings.macos_ui_starting()
    public static let MENUBAR_AWAITING_MARK_CONFIRMATION = MacStrings.macos_copy_menubarawaitingmarkconfirmation()
    public static let MENUBAR_A11Y_PERMISSIONS_NEEDED = MacStrings.macos_copy_menubara11ypermissionsneeded()
    public static let MENUBAR_A11Y_NEEDS_ATTENTION = MacStrings.macos_copy_menubara11yneedsattention()
    public static let MENUBAR_A11Y_ERROR = MacStrings.macos_copy_menubara11yerror()
    public static let MENUBAR_A11Y_STARTING = MacStrings.macos_copy_menubara11ystarting()
    public static let MENUBAR_A11Y_JOURNAL_SETUP_NEEDED = MacStrings.macos_copy_menubara11yjournalsetupneeded()
    public static let MENUBAR_A11Y_WAITING_FOR_JOURNAL = MacStrings.macos_copy_menubara11ywaitingforjournal()
    public static let MENUBAR_A11Y_OBSERVING_SYNC_PAUSED = MacStrings.macos_copy_menubara11yobservingsyncpaused()
    public static let MENUBAR_A11Y_OBSERVING_SAVED_LOCALLY = MacStrings.macos_copy_menubara11yobservingsavedlocally()
    public static let MENUBAR_A11Y_PAUSED = MacStrings.macos_copy_menubara11ypaused()
    public static let MENUBAR_A11Y_OBSERVING_CONNECTED = MacStrings.macos_copy_menubara11yobservingconnected()
    public static let MENUBAR_A11Y_AWAITING_MARK_CONFIRMATION = MacStrings.macos_copy_menubara11yawaitingmarkconfirmation()
    public static let JOURNAL_MARK_HELD = MacStrings.macos_copy_journalmarkheld()
    public static let JOURNAL_MARK_HELD_CAPTION = MacStrings.macos_copy_journalmarkheldcaption()
    public static let JOURNAL_MARK_CONFIRM_ACTION = MacStrings.macos_copy_journalmarkconfirmaction()
    public static let SETTINGS_OBSERVATION_OBSERVING = MacStrings.macos_copy_settingsobservationobserving()
    public static let SETTINGS_OBSERVATION_CONNECTING = MacStrings.macos_ui_connecting()
    public static let SETTINGS_OBSERVATION_PAUSED = MacStrings.macos_ui_paused()
    public static let SETTINGS_OBSERVATION_PROTECTED_VIDEO = MacStrings.macos_copy_settingsobservationprotectedvideo()
    public static let SETTINGS_OBSERVATION_NOT_REACHING = MacStrings.macos_copy_settingsobservationnotreaching()
    public static let SETTINGS_OBSERVATION_NO_JOURNAL = MacStrings.macos_copy_settingsobservationnojournal()
    public static let SETTINGS_OBSERVATION_ATTENTION = MacStrings.macos_copy_settingsobservationattention()
    public static let SETTINGS_OBSERVATION_SAVED_LOCALLY = MacStrings.macos_copy_settingsobservationsavedlocally()
    public static let SETTINGS_OBSERVATION_ERROR = MacStrings.macos_copy_settingsobservationerror()
    public static let SETTINGS_TRY_AGAIN = MacStrings.macos_desktop_shared_copy_tryagain()
    public static let SETTINGS_TRY_AGAIN_IN_FLIGHT = MacStrings.macos_copy_settingstryagaininflight()
    public static let SETTINGS_OBSERVATION_RECOVERY_FALLBACK = MacStrings.macos_uicopy_screenandaudiostoppedandcouldntstartagainonth()
    public static let SETTINGS_SETUP_GROUP_TITLE = MacStrings.macos_copy_settingssetupgrouptitle()
    public static let SETTINGS_SETUP_VERDICT_READY = MacStrings.macos_copy_settingssetupverdictready()
    public static let SETTINGS_SETUP_VERDICT_UNAVAILABLE = MacStrings.macos_copy_settingssetupverdictunavailable()
    public static let SETTINGS_SETUP_SHARED_NOT_REQUIRED = MacStrings.macos_copy_settingssetupsharednotrequired()
    public static let SETTINGS_SETUP_SHARED_COULD_NOT_CHECK = MacStrings.macos_copy_settingssetupsharedcouldnotcheck()
    public static let SETTINGS_SETUP_SHARED_GRANTED = MacStrings.macos_ui_granted()
    public static let SETTINGS_SETUP_SHARED_NOT_GRANTED = MacStrings.macos_copy_settingssetupsharednotgranted()
    public static let SETTINGS_SETUP_SHARED_CHECKING = MacStrings.macos_ui_checking()
    public static let SETTINGS_SETUP_SOL_APP_LABEL = MacStrings.macos_copy_settingssetupsolapplabel()
    public static let SETTINGS_SETUP_SOL_APP_READY = MacStrings.macos_copy_settingssetupsolappready()
    public static let SETTINGS_SETUP_SOL_APP_NEEDS_ATTENTION = MacStrings.macos_copy_settingssetupsolappneedsattention()
    public static let SETTINGS_SETUP_SOL_APP_ACTION = MacStrings.macos_copy_settingssetupsolappaction()
    public static let SETTINGS_SETUP_JOURNAL_APP_LABEL = MacStrings.macos_copy_settingssetupjournalapplabel()
    public static let SETTINGS_SETUP_JOURNAL_APP_READY = MacStrings.macos_ui_installed()
    public static let SETTINGS_SETUP_JOURNAL_APP_NEEDS_ATTENTION = MacStrings.macos_copy_settingssetupjournalappneedsattention()
    public static let SETTINGS_SETUP_JOURNAL_APP_ACTION = MacStrings.macos_copy_settingssetupjournalappaction()
    public static let SETTINGS_SETUP_JOURNAL_LINK_LABEL = MacStrings.macos_desktop_shared_copy_setupjournalcardheading()
    public static let SETTINGS_SETUP_JOURNAL_LINK_READY = MacStrings.macos_ui_linked()
    public static let SETTINGS_SETUP_JOURNAL_LINK_NEEDS_ATTENTION = MacStrings.macos_copy_settingssetupjournallinkneedsattention()
    public static let SETTINGS_SETUP_JOURNAL_LINK_ACTION = MacStrings.macos_copy_settingssetupjournallinkaction()
    public static let SETTINGS_SETUP_SCREEN_RECORDING_LABEL = MacStrings.macos_copy_settingssetupscreenrecordinglabel()
    public static let SETTINGS_SETUP_SCREEN_RECORDING_ACTION = MacStrings.macos_copy_settingssetupscreenrecordingaction()
    public static let SETTINGS_SETUP_MICROPHONE_LABEL = MacStrings.macos_copy_accessibilityexplanation()
    public static let SETTINGS_SETUP_MICROPHONE_ACTION = MacStrings.macos_copy_settingssetupscreenrecordingaction()
    public static let SETTINGS_LAST_DELIVERY_LABEL = MacStrings.macos_copy_settingslastdeliverylabel()
    public static let SETTINGS_LAST_DELIVERY_NEVER = MacStrings.macos_copy_settingslastdeliverynever()
    public static let SETTINGS_LAST_DELIVERY_NOT_LINKED = MacStrings.macos_app_settingslastdeliverynotlinked()
    public static let SETTINGS_DIAGNOSTICS_TITLE = MacStrings.macos_ui_diagnostics()
    public static let SETTINGS_DIAGNOSTICS_INTRO = MacStrings.macos_copy_settingsdiagnosticsintro()
    public static let SETTINGS_DIAGNOSTICS_SHOW = MacStrings.macos_copy_settingsdiagnosticsshow()
    public static let SETTINGS_DIAGNOSTICS_HIDE = MacStrings.macos_copy_settingsdiagnosticshide()
    public static let SETTINGS_DIAGNOSTICS_COPY = MacStrings.macos_copy_descriptionparagraph1()
    public static let SETTINGS_DIAGNOSTICS_COPIED = MacStrings.macos_about_copied()
    public static let SETTINGS_DIAGNOSTICS_COPY_ANNOUNCEMENT = MacStrings.macos_copy_limitsdisclosure()
    public static let SETTINGS_DIAGNOSTICS_COPY_FAILED = MacStrings.macos_copy_accessibilitycaution()
    public static let SETTINGS_DIAGNOSTICS_CHECKED_AT = MacStrings.macos_copy_settingsdiagnosticscheckedat()
    public static let SETTINGS_DIAGNOSTICS_APP_VERSION = MacStrings.macos_copy_settingsdiagnosticsappversion()
    public static let SETTINGS_DIAGNOSTICS_SCREEN_RECORDING = MacStrings.macos_copy_settingssetupscreenrecordinglabel()
    public static let SETTINGS_DIAGNOSTICS_MICROPHONE = MacStrings.macos_copy_accessibilityexplanation()
    public static let SETTINGS_DIAGNOSTICS_SCREEN_AND_AUDIO = MacStrings.macos_desktop_shared_app_sourcestitle()
    public static let SETTINGS_DIAGNOSTICS_LAST_JOURNAL_CONNECTION = MacStrings.macos_copy_settingsdiagnosticslastjournalconnection()
    public static let SETTINGS_DIAGNOSTICS_INGEST_REASON = MacStrings.macos_copy_settingsdiagnosticsingestreason()
    public static let SETTINGS_DIAGNOSTICS_INGEST_ROUTE = MacStrings.macos_copy_settingsdiagnosticsingestroute()
    public static let SETTINGS_DIAGNOSTICS_JOURNAL_LINK = MacStrings.macos_copy_settingsdiagnosticsjournallink()
    public static let SETTINGS_DIAGNOSTICS_NO_LINK_REFUSALS = MacStrings.macos_copy_settingsdiagnosticsnolinkrefusals()
    public static func diagnosticsStreamLimitRefused(count: Int, last: String) -> String {
        MacStrings.macos_copy_yourjournalturnedawayrequestsatits_native(MacStrings.number(count), "\(last)")
    }
    // ⛔ Never "lost the connection": this line exists only because the journal
    // sent a reset, which it can only do over a live link. Saying the
    // connection dropped would print the misleading symptom back as the
    // diagnosis, which is the failure this row was added to end.
    public static func diagnosticsStreamDropped(count: Int, last: String) -> String {
        MacStrings.macos_copy_yourjournalendedrequestsearlylast_native(MacStrings.number(count), "\(last)")
    }
    public static let SETTINGS_DIAGNOSTICS_RECENT_STATE_CODES = MacStrings.macos_copy_settingsdiagnosticsrecentstatecodes()
    public static let SETTINGS_DIAGNOSTICS_GRANTED = MacStrings.macos_ui_granted()
    public static let SETTINGS_DIAGNOSTICS_NOT_GRANTED = MacStrings.macos_copy_settingssetupsharednotgranted()
    public static let SETTINGS_DIAGNOSTICS_CHECKING = MacStrings.macos_ui_checking()
    public static let SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK = MacStrings.macos_copy_settingssetupsharedcouldnotcheck()
    public static let SETTINGS_DIAGNOSTICS_ON = MacStrings.macos_desktop_shared_app_settingsdiagnosticson()
    public static let SETTINGS_DIAGNOSTICS_PAUSED = MacStrings.macos_ui_paused()
    public static let SETTINGS_DIAGNOSTICS_OFF = MacStrings.macos_desktop_shared_app_microphonemodeoff()
    public static let SETTINGS_DIAGNOSTICS_ERROR = MacStrings.macos_ui_error()
    public static let SETTINGS_DIAGNOSTICS_NO_CONNECTION = MacStrings.macos_copy_settingsdiagnosticsnoconnection()
    public static let SETTINGS_DIAGNOSTICS_NO_RECENT_CODES = MacStrings.macos_copy_settingsdiagnosticsnorecentcodes()
    public static let JOURNAL_ADDRESSES_LABEL = MacStrings.macos_ui_addresses()
    public static let JOURNAL_RELAY_LABEL = MacStrings.macos_ui_relay()
    public static let JOURNAL_RELAY_OFF = MacStrings.macos_desktop_shared_app_microphonemodeoff()
    public static func journalRelayOn(host: String) -> String {
        MacStrings.macos_copy_on("\(host)")
    }
    public static let JOURNAL_CONNECTED_THROUGH_LABEL = MacStrings.macos_copy_journalconnectedthroughlabel()
    public static let JOURNAL_CONNECTED_THROUGH_RELAY = MacStrings.macos_copy_journalconnectedthroughrelay()
    public static let JOURNAL_ADDRESSES_TRIED_LABEL = MacStrings.macos_copy_journaladdressestriedlabel()
    /// `tried A` · `tried A and B` · `tried A, B and C`
    public static func journalTriedAddresses(_ addresses: [String]) -> String? {
        guard let last = addresses.last else { return nil }
        guard addresses.count > 1 else { return MacStrings.macos_copy_tried("\(last)") }
        return MacStrings.macos_copy_triedand("\(addresses.dropLast().joined(separator: ", "))", "\(last)")
    }
    public static let SETTINGS_PERMISSIONS_SCREEN_RECORDING_RESET_HINT = MacStrings.macos_copy_settingspermissionsscreenrecordingresethint()
    public static let SETTINGS_NEXT_GRANT_PERMISSIONS = MacStrings.macos_copy_settingsnextgrantpermissions()
    public static let SETTINGS_PERMISSIONS_SCREEN_EXPLAINER = MacStrings.macos_copy_settingspermissionsscreenexplainer()
    public static let SETTINGS_PERMISSIONS_MIC_EXPLAINER = MacStrings.macos_copy_settingspermissionsscreenexplainer()
    public static let SETTINGS_PERMISSIONS_MIC_DENIED = MacStrings.macos_copy_settingspermissionsmicdenied()
    public static let SETTINGS_PERMISSIONS_MIC_RESTRICTED = MacStrings.macos_copy_settingspermissionsmicrestricted()
    public static let SETTINGS_PERMISSIONS_OPEN_SYSTEM_SETTINGS = MacStrings.macos_copy_settingspermissionsopensystemsettings()
    public static let SETTINGS_PERMISSIONS_LIVE_ON = MacStrings.macos_desktop_shared_app_settingsdiagnosticson()
    public static let SETTINGS_PERMISSIONS_LIVE_ON_HINT = MacStrings.macos_copy_settingspermissionsliveonhint()
    public static let SETTINGS_PERMISSIONS_LIVE_PAUSED_HINT = MacStrings.macos_copy_settingspermissionslivepausedhint()
    public static let SETTINGS_PERMISSIONS_LIVE_PAUSED_ACTIVITY_HINT = MacStrings.macos_copy_settingspermissionslivepausedactivityhint()

    /// The paused hint must not say nothing goes in while activity still does.
    public static func pausedHint(activityGoesOn: Bool) -> String {
        activityGoesOn ? SETTINGS_PERMISSIONS_LIVE_PAUSED_ACTIVITY_HINT : SETTINGS_PERMISSIONS_LIVE_PAUSED_HINT
    }
    public static let SETTINGS_PERMISSIONS_LIVE_OFF = MacStrings.macos_desktop_shared_app_microphonemodeoff()
    public static let SETTINGS_PERMISSIONS_LIVE_OFF_HINT = MacStrings.macos_copy_settingspermissionsliveoffhint()
    public static let SETTINGS_PERMISSIONS_LIVE_NOT_RUNNING = MacStrings.macos_copy_settingspermissionslivenotrunning()
    public static let SETTINGS_PERMISSIONS_CHECK_STATUS = MacStrings.macos_copy_settingspermissionscheckstatus()
    public static let SETTINGS_PERMISSIONS_MICROPHONE_BREADCRUMB = MacStrings.macos_copy_settingspermissionsmicrophonebreadcrumb()
    public static let SETTINGS_PERMISSIONS_SCREEN_RECORDING_BREADCRUMB = MacStrings.macos_copy_settingspermissionsscreenrecordingbreadcrumb()
    public static let SETTINGS_PERMISSIONS_SCREEN_WAITING = MacStrings.macos_copy_settingspermissionsscreenwaiting()
    public static let SETTINGS_PERMISSIONS_SCREEN_REOPEN = MacStrings.macos_copy_settingspermissionsscreenreopen()
    public static let SETTINGS_PERMISSIONS_ENABLE_SCREEN_RECORDING = MacStrings.macos_copy_settingspermissionsenablescreenrecording()
    public static let SETTINGS_PERMISSIONS_ENABLE_MICROPHONE = MacStrings.macos_copy_settingspermissionsenablemicrophone()
    public static let SETTINGS_HELP_ICON_RECORDING = MacStrings.macos_copy_settingsobservationobserving()
    public static let SETTINGS_HELP_ICON_CONNECTING = MacStrings.macos_ui_connecting()
    public static let SETTINGS_HELP_ICON_PAUSED = MacStrings.macos_ui_pausedoreverysource()
    public static let SETTINGS_HELP_ICON_ATTENTION = MacStrings.macos_copy_settingsobservationattention()
    public static let SETTINGS_HELP_ICON_OFFLINE = MacStrings.macos_copy_settingsobservationsavedlocally()
    public static let SETTINGS_HELP_ICON_ERROR = MacStrings.macos_copy_settingsobservationerror()
    public static let SETTINGS_LOG_EXPORT_TITLE = MacStrings.macos_desktop_shared_copy_settingslogexporttitle()
    public static let SETTINGS_LOG_EXPORT_INTRO = MacStrings.macos_copy_settingslogexportintro()
    public static let SETTINGS_LOG_EXPORT_ACTION = MacStrings.macos_copy_settingslogexportaction()
    public static let SETTINGS_LOG_EXPORT_WORKING = MacStrings.macos_copy_settingslogexportworking()
    public static let SETTINGS_LOG_EXPORT_SAVE = MacStrings.macos_desktop_shared_copy_settingslogexportsave()
    public static let SETTINGS_LOG_EXPORT_FAILED = MacStrings.macos_copy_settingslogexportfailed()
    public static let SETTINGS_LOG_EXPORT_PARTIAL = MacStrings.macos_copy_settingslogexportpartial()
    public static let SETTINGS_LOG_EXPORT_EMPTY = MacStrings.macos_copy_settingslogexportempty()
    public static let SETTINGS_LOG_EXPORT_WRITE_FAILED = MacStrings.macos_copy_settingslogexportwritefailed()
    public static let SETTINGS_LOG_EXPORT_PREVIEW_SUBSET = MacStrings.macos_copy_settingslogexportpreviewsubset()
    // The status card names the same state the help legend names, in the same words,
    // so the red dot and its explanation cannot drift apart.
    public static let STATUS_CAPTURE_ERROR_TITLE = MacStrings.macos_copy_settingsobservationerror()
    public static let ERROR_LOGIN_ITEM = MacStrings.macos_copy_errorloginitem()
    public static let ERROR_SAVE_CONFIG = MacStrings.macos_copy_errorsaveconfig()
    public static let ERROR_START_OBSERVING = MacStrings.macos_uicopy_screenandaudiocouldntstartcheckpermissionsins()

    public static func menubarErrorOpenSettings(_ message: String) -> String {
        MacStrings.macos_copy_error("\(message)")
    }

    public static func settingsSetupVerdictNeedsAttention(_ count: Int) -> String {
        MacStrings.macos_uicopy_thingsneedattention_plural(count)
    }

    // Keyboard shortcut
    public static let SHORTCUT_SECTION_TITLE = MacStrings.macos_copy_shortcutsectiontitle()
    public static let SHORTCUT_SECTION_DESCRIPTION = MacStrings.macos_copy_shortcutsectiondescription()
    public static let SHORTCUT_OFF = MacStrings.macos_desktop_shared_app_microphonemodeoff()
    public static let SHORTCUT_SET = MacStrings.macos_copy_shortcutset()
    public static let SHORTCUT_PRESS = MacStrings.macos_copy_shortcutpress()
    public static let SHORTCUT_CLEAR = MacStrings.macos_ui_clear()
    public static let SHORTCUT_CANCEL = MacStrings.macos_desktop_shared_setup_cancel()
    public static let SHORTCUT_ERROR_CMD_OR_CTRL = MacStrings.macos_copy_shortcuterrorcmdorctrl()
    public static let SHORTCUT_ERROR_CONFLICT = MacStrings.macos_copy_shortcuterrorconflict()
    public static let SHORTCUT_ERROR_UNAVAILABLE = MacStrings.macos_copy_shortcuterrorunavailable()
    public static let SHORTCUT_MENU_RECOVERY = MacStrings.macos_copy_shortcutmenurecovery()
    public static let SHORTCUT_PERMISSION_NOTE = MacStrings.macos_copy_shortcutpermissionnote()

    // Screen failure
    public static let SCREEN_INTAKE_STOPPED = MacStrings.macos_copy_screenintakestopped()
    public static let SCREEN_INTAKE_COULD_NOT_START = MacStrings.macos_copy_screenintakecouldnotstart()

    // Microphones empty state
    public static let MICROPHONES_EMPTY_TITLE = MacStrings.macos_copy_microphonesemptytitle()
    public static let MICROPHONES_EMPTY_ACCESS_DESCRIPTION = MacStrings.macos_copy_microphonesemptyaccessdescription()
    public static let MICROPHONES_EMPTY_OPEN_PERMISSIONS = MacStrings.macos_copy_microphonesemptyopenpermissions()
    public static let MICROPHONES_EMPTY_CONNECT_DESCRIPTION = MacStrings.macos_copy_microphonesemptyconnectdescription()
    public static let MICROPHONES_EMPTY_OPEN_SOUND = MacStrings.macos_copy_microphonesemptyopensound()

    public enum Websites {
        public static let DESCRIPTION_PARAGRAPH_1 = MacStrings.macos_uicopy_whileawebsiteyouleaveoutshowsinanysafarichrom()
        public static let HOW_THIS_WORKS = MacStrings.macos_ui_howthisworks()
        public static func descriptionParagraph2(macOSMajor: Int) -> String {
            MacStrings.macos_uicopy_tochecksolstonereadstheaddressofthepageeachsa("\(accessibilityName(macOSMajor: macOSMajor))")
        }
        public static let LIMITS_DISCLOSURE = MacStrings.macos_uicopy_checkedinsafarichromeedgeandbravefirefoxother()
        /// What System Settings calls this list on the owner's macOS.
        public static func accessibilityName(macOSMajor: Int) -> String {
            macOSMajor >= 27 ? MacStrings.macos_ui_devicecontrolanddata() : MacStrings.macos_ui_accessibility()
        }
        public static func accessibilityCaution(macOSMajor: Int) -> String {
            MacStrings.macos_uicopy_toleavewebsitesoutsolstoneneedssoitcanreadwhi("\(accessibilityName(macOSMajor: macOSMajor))")
        }
        public static let NOT_KEPT_OUT_YET = MacStrings.macos_uicopy_untilitsallowedthesewebsitesarentkeptoutofyou()
        public static func errorNeedsAccessibility(macOSMajor: Int) -> String {
            MacStrings.macos_uicopy_allowfirstsosolstonecantellwhichwebsiteawindo("\(accessibilityName(macOSMajor: macOSMajor))")
        }
        public static func activityAccessibilityHelp(macOSMajor: Int) -> String {
            MacStrings.macos_uicopy_withactivitycanaddbrowseraddressestoyourjourn("\(accessibilityName(macOSMajor: macOSMajor))")
        }
        public static func activityAccessibilityOffInMacOS(macOSMajor: Int) -> String {
            MacStrings.macos_ui_macoshasofffor("\(accessibilityName(macOSMajor: macOSMajor))")
        }
        public static let OPEN_SYSTEM_SETTINGS = MacStrings.macos_settings_opensystemsettings()
        public static func browserCaution(browser: String) -> String {
            MacStrings.macos_uicopy_solstonecantreadpageaddressesinrightnowsostay("\(browser)", "\(browser)")
        }
        public static let ERROR_INVALID_ADDRESS = MacStrings.macos_copy_errorinvalidaddress()
        public static let ERROR_LIMIT_REACHED = MacStrings.macos_copy_errorlimitreached()
    }
}
