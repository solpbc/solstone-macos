import SolstoneCore

public enum UICopy {
    enum Migration {
        static let deferChoice = "not now"
        static let replaceOfferTitle = "is this replacing one of your devices?"
        static let replaceOfferBody = "you can keep both, or choose a device for this one to replace."
        static let chooseDevice = "choose a device"
        static let keepBoth = "keep both"
        static let pickerTitle = "choose a device"
        static let pickerEmpty = "no other paired devices"
        static let cancel = "cancel"
        static let replaceConfirmTitle = "replace \"{selected_device_label}\"?"
        static let replaceConfirmBody = "this device continues its name and history. the selected device will lose access to your journal."
        static let replaceDevice = "replace device"
        static let offlineTitle = "can't reach your journal"
        static let offlineBody = "anything waiting to send stays on this device. try again when your journal is reachable."
        static let tryAgain = "try again"
        static let storageUnavailableTitle = "saved connection unavailable"
        static let storageUnavailableBody = "this device couldn't read its saved connection. anything waiting to send hasn't been removed."
        static let technicalDetails = "technical details"
        static let decidingTitle = "saving your choice"
        static let decisionUnknownTitle = "checking your choice"
        static let decisionUnknownBody = "your journal hasn't confirmed the result yet."
        static let checkAgain = "check again"
        static let listUnavailableTitle = "devices unavailable"
        static let listUnavailableBody = "couldn't load the devices in your journal. try again when your journal is reachable."
        static let targetMissingTitle = "device no longer available"
        static let targetMissingBody = "that device is no longer listed in your journal. choose another device, or keep both."
        static let decisionRefusedTitle = "choice needs attention"
        static let decisionRefusedBody = "your journal couldn't apply this choice. your current connection still works."
        static let replaceConfirmTitleFallback = "replace the selected device?"
    }

    public static let SOURCES_TITLE = "sources"
    // Audio health
    public static let AUDIO_SOURCE_SYSTEM = "system audio"
    public static let AUDIO_SOURCE_MICROPHONE = "a microphone"
    /// Owner-facing audio health, naming each source. Nil when nothing needs saying.
    public static func audioIssue(recovering: [String], recovered: [String]) -> String? {
        func list(_ names: [String]) -> String {
            let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return unique.count <= 1 ? (unique.first ?? "") : unique.dropLast().joined(separator: ", ") + " and " + unique.last!
        }
        if !recovering.isEmpty {
            let verb = Set(recovering).count > 1 ? "aren't" : "isn't"
            return "\(list(recovering)) \(verb) coming through right now. the solstone app is trying again on its own."
        }
        if !recovered.isEmpty {
            let verb = Set(recovered).count > 1 ? "are" : "is"
            return "\(list(recovered)) dropped out earlier and \(verb) back. part of this segment may be missing."
        }
        return nil
    }

    // Microphones
    public static let MICROPHONES_LIST_CAPTION = "every microphone that's on goes into your journal."
    public static let MICROPHONE_MODE_WHEN_IN_USE = "when another app uses it"
    public static let MICROPHONE_MODE_ALWAYS = "always"
    public static let MICROPHONE_MODE_OFF = "off"
    public static let MICROPHONE_MODE_HELP = "a bluetooth headset sounds worse while its microphone is open, so by default it only goes into your journal while another app, such as a call app, is already using it."
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    public static let SOURCES_HELP = "what you turn on here goes into your journal. each one is on unless you turn it off."
    public static let SOURCES_NONE = "every source is off"
    public static let SOURCES_NONE_REASON = "nothing new is taken in until you turn one back on. turning sources off doesn't hold back what's already kept on this mac."
    public static let SOURCES_BROWSER_PAGES = "browser pages"

    // Group & store
    public static let SOURCES_BROWSERS_GROUP_TITLE = "browsers"
    public static let SOURCES_BROWSERS_NO_HISTORY = "no browser connected yet"
    public static let SOURCES_BROWSERS_NO_STORE = "the solstone extension isn't in the browser stores yet."
    public static let SOURCES_BROWSERS_STORES_CONFIGURED = "add the solstone extension to Chrome, Edge or Firefox on this mac, then choose which sites to share. what you share goes into your journal."
    public static func sourcesBrowserAddAction(browser: String) -> String { "add to \(browser)" }
    public static func sourcesBrowserLaunchFailure(browser: String) -> String { "couldn't open the store page in \(browser)." }

    // Rows
    public static func sourcesBrowserRowLabel(browser: String, profileCount: Int) -> String {
        profileCount > 1 ? "\(browser) · \(profileCount) profiles" : browser
    }
    public static let SOURCES_BROWSER_CONNECTED_NOW = "connected now"
    public static func sourcesBrowserLastSeen(_ relative: String) -> String { "last seen \(relative)" }
    public static let SOURCES_BROWSER_NEEDS_EXT_UPDATE = "needs an extension update"
    public static let SOURCES_BROWSER_NEEDS_APP_UPDATE = "needs a solstone app update"

    // State lines
    public static let SOURCES_BROWSER_INTAKE_OFF = "browser pages are off. nothing new is taken in from your browsers."
    public static let SOURCES_BROWSER_DRAINING = "browser pages are off. nothing new is taken in from your browsers; turning them off doesn't hold back what's already kept on this mac."
    public static let SOURCES_BROWSER_NEWER_EXTENSION = "the solstone extension in a browser needs a newer solstone app. look under updates."
    public static let SOURCES_BROWSER_FULL = "the room on this mac for what you share from your browsers is full."
    public static let SOURCES_BROWSER_STALE = "some browser pages have waited more than a week to go into your journal. they're still kept on this mac."
    public static let SOURCES_BROWSER_CANNOT_START = "browser pages can't start right now."
    public static let SOURCES_BROWSER_UNKNOWN = "browser status isn't known yet."
    public static let SOURCES_BROWSER_HELD = "new browser pages aren't being taken in right now."
    public static let SOURCES_BROWSER_LOST_AND_HELD = "some browser pages couldn't be kept, so they won't go into your journal. new browser pages aren't being taken in right now."
    public static let SOURCES_BROWSER_PAUSED = "paused with the rest of the solstone app. pausing doesn't hold back what's already taken in."
    public static let SOURCES_BROWSER_DELIVERY_FAILED = "kept on this mac, not reaching your journal right now"
    public static let SOURCES_BROWSER_REGISTRATION_BROKEN = "your browsers can't find the solstone app on this mac."
    public static let SOURCES_BROWSER_DISCARD = "discard waiting browser pages"
    public static let SOURCES_BROWSER_DISCARD_CONFIRM = "browser pages still waiting to be sent will be removed from this device."
    public static let SOURCES_BROWSER_DISCARD_COMMIT = "discard pages"
    public static let SOURCES_BROWSER_DISCARDED = "discarded"
    public static let SOURCES_BROWSER_DISCARD_FAILED = "couldn't finish discarding. what's left is still on this mac."

    // Repair
    public static let SOURCES_BROWSER_REPAIR_ACTION = "repair"
    public static let SOURCES_BROWSER_REPAIRED = "repaired"
    public static func sourcesBrowserRepairFailed(reason: String) -> String { "couldn't repair: \(reason)" }
    public static func browserSetupReason(_ code: String?) -> String {
        switch code {
        case "listener_down": return "the app isn't available"
        case "endpoint_collision": return "the app's connection couldn't be checked"
        case "helper_path_not_bundled", "unsafe_helper_path", "invalid_contract", "invalid_template":
            return "the app's files couldn't be checked"
        case "manifest_missing", "manifest_change_required", "unsafe_registration_directory", "unsafe_manifest", "manifest_verification_failed", "registration_io":
            return "the browser setup couldn't be changed"
        default: return "the setup couldn't be checked"
        }
    }
    public static let SOURCES_BROWSER_FOOTNOTE = "the solstone extension works in Chrome, Edge and Firefox. it doesn't run in private windows. that covers this extension only."

    // Menu row
    public static func menubarBrowsersLive(_ brands: String) -> String { "browsers · \(brands)" }
    public static let MENUBAR_BROWSERS_NONE_CONNECTED = "browsers · none connected now"
    public static let MENUBAR_BROWSERS_NONE_YET = "browsers · none yet"
    public static let MENUBAR_BROWSERS_OFF = "browsers · off"
    public static let MENUBAR_BROWSERS_PAUSED = "browsers · paused"

    // Headlines
    public static let SOURCES_BROWSER_HEADLINE_READY = "on · browser pages only"
    public static let SOURCES_BROWSER_HEADLINE_WAITING = "on · waiting for a browser to connect"

    // Legend footnote
    public static let SETTINGS_HELP_BROWSER_FOOTNOTE = "the solstone extension shows the same marks in your browser's toolbar, for what you share from that browser."

    // Diagnostics labels
    public static let DIAGNOSTICS_BROWSER_PAGES_LABEL = "browser pages"
    public static let DIAGNOSTICS_BROWSERS_SEEN_LABEL = "browsers seen"
    public static let DIAGNOSTICS_BROWSER_SETUP_LABEL = "browser setup"
#else
    public static let SOURCES_HELP = "what you turn on here goes into your journal. both are on unless you turn one off."
    public static let SOURCES_NONE = "both sources are off"
    public static let SOURCES_NONE_REASON = "nothing is going into your journal until you turn one back on."
#endif
    public static let SOURCES_MICROPHONE = "microphone"
    public static let SOURCES_SCREEN = "screen and system audio"
    public static let SOURCES_OFF = "off"
    public static let SOURCES_STARTING = "starting…"
    public static let SOURCES_OPEN_ACTION = "open sources →"
    public static let PERMISSIONS_OPEN_ACTION = "open permissions →"

    // Selected, but macOS hasn't granted either one.
    public static let SOURCES_UNAVAILABLE = "the source you turned on didn't start"
    public static let SOURCES_UNAVAILABLE_REASON = "the device may be in use by another app, or unplugged."
    public static let SOURCES_NONE_GRANTED = "what you turned on isn't granted yet"
    public static let SOURCES_GRANT_OR_CHANGE = "grant it below, or turn on the other source instead."

    // Per-source notices, shown beside a session that is running on the other source.
    public static let SOURCES_MIC_DENIED = "microphone permission not granted. screen and system audio can run on their own."
    public static let SOURCES_SCREEN_DENIED = "screen permission not granted. microphone can run on its own."
    public static let SOURCES_MIC_UNAVAILABLE = "microphone unavailable. screen and system audio are running."
    public static let SOURCES_SCREEN_UNAVAILABLE = "screen and system audio unavailable. microphone is running."

    public static let SOURCES_RESTART_READY = "granted. solstone needs to restart before what's on your screen can go into your journal."
    public static let SOURCES_RESTART = "restart now"

    public static func sourceNames(_ sources: CaptureSources) -> String {
        switch (sources.contains(.microphone), sources.contains(.screen)) {
        case (true, true): return "microphone, screen and system audio"
        case (true, false): return SOURCES_MICROPHONE
        case (false, true): return SOURCES_SCREEN
        case (false, false): return SOURCES_OFF
        }
    }

    public static func sourceStatus(_ sources: CaptureSources, isPaused: Bool = false) -> String {
        guard !sources.isEmpty else { return SOURCES_OFF }
        return "\(isPaused ? "paused" : "on") · \(sourceNames(sources))"
    }

    public static let JOURNAL_WINDOW_TITLE = "your journal"
    public static let JOURNAL_WINDOW_LOADING = "opening your journal…"
    public static let JOURNAL_WINDOW_ERROR = "your journal couldn't load"
    public static let JOURNAL_WINDOW_RETRY = "try again"
    public static let JOURNAL_MODE_THIS_MAC_LABEL = "this mac"
    public static let JOURNAL_MODE_ANOTHER_MACHINE_LABEL = "another device"
    public static let PAIRING_LINK_PLACEHOLDER = "paste pairing link"
    public static let PAIRING_NOTENTITLED_RECOVERY = "your journal is paired, but it isn't on the paid plan, so it can't sync over the internet. you can still reach it directly, without the plan, whenever your journal is reachable."
    public static let PAIRING_DISCONNECT_CONFIRM = "disconnect this mac from your journal? your journal keeps everything. you can pair again anytime."
    public static let PAIRING_SAVE_FAILED = "pairing worked, but this mac couldn't save it. try again."
    public static let SAME_MACHINE_LINK_ALREADY_LINKED = "already linked to your journal on this mac."
    public static let SAME_MACHINE_LINK_UNREACHABLE = "couldn't reach your journal on this mac. make sure the journal app is open, then try again."
    public static let SAME_MACHINE_LINK_REFUSED = "your journal on this mac didn't accept the request to link. try again, or paste a pairing link from your journal's network app below."
    public static let SAME_MACHINE_LINK_UNEXPECTED = "your journal on this mac sent back something the solstone app couldn't use. try again, or paste a pairing link from your journal's network app below."
    public static let SAME_MACHINE_LINK_UNFINISHED = "linking didn't finish. try again."
    public static let SAME_MACHINE_LINK_CREDENTIALS_UNAVAILABLE = "this mac couldn't read its saved connection, so it can't link yet. try again, or restart solstone."
    public static let SAME_MACHINE_LINK_OTHER_JOURNAL = "this mac is already paired with a journal on another device."
    public static func relinkNeedsPairingLink(address: String?) -> String {
        guard let address else {
            return "linking again takes a pairing link. get one from your journal's network app and paste it below."
        }
        return "this mac is set up for a journal at \(address), so linking again takes a pairing link from that journal. get one from its network app and paste it below."
    }
    public static let JOURNAL_MARK_CONFIRM_QUESTION = "does this match your journal?"
    public static let JOURNAL_MARK_CONFIRM_SUBTEXT = "your journal shows this same mark in its network app. it should match, exactly."
    public static let JOURNAL_MARK_CONFIRM_BUTTON = "yes, this is my journal"
    public static let JOURNAL_MARK_MISMATCH_BUTTON = "that doesn't match"
    public static let JOURNAL_MARK_CONNECTING = "connecting…"
    public static let JOURNAL_MARK_UNVERIFIED_TITLE = "couldn't verify"
    public static let JOURNAL_MARK_UNVERIFIED_BODY = "we couldn't confirm your journal's mark in time. you can continue if you're sure this is your journal, or cancel and try again."
    public static let JOURNAL_MARK_UNVERIFIED_CONTINUE_BUTTON = "continue anyway"
    public static let JOURNAL_MARK_UNVERIFIED_CANCEL_BUTTON = "cancel pairing"
    public static let JOURNAL_MARK_MISMATCH_TITLE = "not connected"
    public static let JOURNAL_MARK_MISMATCH_BODY = "you said this mark doesn't match the one your journal shows, so we didn't connect this mac. you may have pasted the wrong link, or something isn't right. try again, or reach us and we'll help."
    public static let JOURNAL_MARK_MISMATCH_FRESH_LINK = "get a fresh link"
    public static let JOURNAL_MARK_MISMATCH_SUPPORT = "email support@solstone.app"
    public static let SETTINGS_PREREQ_PERMISSIONS = "you'll also need to grant permissions →"
    public static let SETTINGS_NEXT_CONNECT_JOURNAL = "next: connect your journal →"
    public static let SETTINGS_NEXT_CHECK_STATUS = "next: check status →"
    public static let SETTINGS_LOCAL_JOURNAL_FOUND_EXISTING = "found an existing journal on this mac"
    public static let SETTINGS_LOCAL_JOURNAL_INSTALL_EXISTING = "install the journal app to bring it back online"
    public static let SETTINGS_LOCAL_JOURNAL_OPEN_EXISTING = "open the journal app to bring it back online"
    public static let SETTINGS_JOURNAL_OPEN = "open journal"
    public static let SETTINGS_TAB_DONE_A11Y = "configured"
    public static let SETTINGS_TAB_ATTENTION_A11Y = "needs attention"
    public static let SETTINGS_TAB_UPDATES_DONE_A11Y = "solstone is up to date"
    public static let SETTINGS_ATTENTION_PERMISSIONS = "permissions needed"
    public static let SETTINGS_ATTENTION_PRIVATE_WINDOWS = "can't check private windows in Safari, Chrome, Edge and Brave"
    public static let PRIVATE_WINDOWS_CHECKING = "checking Accessibility access…"
    public static let SETTINGS_ATTENTION_JOURNAL = "journal setup needed"
    public static let SETTINGS_ATTENTION_UPDATE_AVAILABLE = "update available"
    public static let SETTINGS_ATTENTION_UPDATE_CHECK_FAILED = "update check failed"
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    public static let MENUBAR_SOURCES_OFF_OPEN_SETTINGS = "every source is off · open sources →"
#else
    public static let MENUBAR_SOURCES_OFF_OPEN_SETTINGS = "both sources are off · open sources →"
#endif
    public static let MENUBAR_NO_SOURCE_OPEN_SETTINGS = "waiting on a permission · open permissions →"
    public static let MENUBAR_OBSERVING_CONNECTED = "on, connected"
    public static let MENUBAR_OBSERVATION_WEDGE_OPEN_SETTINGS = "needs attention · open settings →"
    public static let MENUBAR_OBSERVING_OFFLINE_SAVED_LOCALLY = "on, offline (saved locally) →"
    public static let MENUBAR_LOCAL_ONLY_SETUP_JOURNAL = "on · set up your journal →"
    public static let MENUBAR_SYNC_PAUSED = "on, sync paused"
    public static let MENUBAR_STARTING = "starting…"
    public static let MENUBAR_AWAITING_MARK_CONFIRMATION = "on · confirm your journal's mark →"
    public static let MENUBAR_A11Y_PERMISSIONS_NEEDED = "solstone · permissions needed"
    public static let MENUBAR_A11Y_NEEDS_ATTENTION = "solstone · needs attention"
    public static let MENUBAR_A11Y_ERROR = "solstone · error"
    public static let MENUBAR_A11Y_STARTING = "solstone · starting"
    public static let MENUBAR_A11Y_JOURNAL_SETUP_NEEDED = "solstone · journal setup needed"
    public static let MENUBAR_A11Y_WAITING_FOR_JOURNAL = "solstone · waiting for journal"
    public static let MENUBAR_A11Y_OBSERVING_SYNC_PAUSED = "solstone · on, sync paused"
    public static let MENUBAR_A11Y_OBSERVING_SAVED_LOCALLY = "solstone · on, saved locally"
    public static let MENUBAR_A11Y_PAUSED = "solstone · paused"
    public static let MENUBAR_A11Y_OBSERVING_CONNECTED = "solstone · on, connected"
    public static let MENUBAR_A11Y_AWAITING_MARK_CONFIRMATION = "solstone · confirm your journal's mark"
    public static let JOURNAL_MARK_HELD = "waiting for you to confirm your journal's mark"
    public static let JOURNAL_MARK_HELD_CAPTION = "nothing waiting goes into your journal until you do."
    public static let JOURNAL_MARK_CONFIRM_ACTION = "confirm your journal's mark"
    public static let SETTINGS_OBSERVATION_OBSERVING = "on · reaching your journal"
    public static let SETTINGS_OBSERVATION_CONNECTING = "connecting"
    public static let SETTINGS_OBSERVATION_PAUSED = "paused"
    public static let SETTINGS_OBSERVATION_NOT_REACHING = "on · not reaching your journal"
    public static let SETTINGS_OBSERVATION_NO_JOURNAL = "on · no journal"
    public static let SETTINGS_OBSERVATION_ATTENTION = "needs your attention"
    public static let SETTINGS_OBSERVATION_SAVED_LOCALLY = "on · saved on this mac, not reaching your journal right now"
    public static let SETTINGS_OBSERVATION_ERROR = "something's broken"
    public static let SETTINGS_TRY_AGAIN = "try again"
    public static let SETTINGS_TRY_AGAIN_IN_FLIGHT = "trying again…"
    public static let SETTINGS_OBSERVATION_RECOVERY_FALLBACK = "intake stopped and couldn't restart on its own."
    public static let SETTINGS_SETUP_GROUP_TITLE = "check my setup"
    public static let SETTINGS_SETUP_VERDICT_READY = "your setup is ready"
    public static let SETTINGS_SETUP_VERDICT_UNAVAILABLE = "some setup checks are unavailable"
    public static let SETTINGS_SETUP_SHARED_NOT_REQUIRED = "not needed on this mac"
    public static let SETTINGS_SETUP_SHARED_COULD_NOT_CHECK = "couldn't check"
    public static let SETTINGS_SETUP_SHARED_GRANTED = "granted"
    public static let SETTINGS_SETUP_SHARED_NOT_GRANTED = "not granted"
    public static let SETTINGS_SETUP_SHARED_CHECKING = "checking"
    public static let SETTINGS_SETUP_SOL_APP_LABEL = "solstone app"
    public static let SETTINGS_SETUP_SOL_APP_READY = "in Applications"
    public static let SETTINGS_SETUP_SOL_APP_NEEDS_ATTENTION = "needs to be moved"
    public static let SETTINGS_SETUP_SOL_APP_ACTION = "open Applications →"
    public static let SETTINGS_SETUP_JOURNAL_APP_LABEL = "journal app"
    public static let SETTINGS_SETUP_JOURNAL_APP_READY = "installed"
    public static let SETTINGS_SETUP_JOURNAL_APP_NEEDS_ATTENTION = "not installed"
    public static let SETTINGS_SETUP_JOURNAL_APP_ACTION = "open journal settings →"
    public static let SETTINGS_SETUP_JOURNAL_LINK_LABEL = "your journal"
    public static let SETTINGS_SETUP_JOURNAL_LINK_READY = "linked"
    public static let SETTINGS_SETUP_JOURNAL_LINK_NEEDS_ATTENTION = "not linked"
    public static let SETTINGS_SETUP_JOURNAL_LINK_ACTION = "connect your journal →"
    public static let SETTINGS_SETUP_SCREEN_RECORDING_LABEL = "screen recording"
    public static let SETTINGS_SETUP_SCREEN_RECORDING_ACTION = "grant access →"
    public static let SETTINGS_SETUP_MICROPHONE_LABEL = "microphone"
    public static let SETTINGS_SETUP_MICROPHONE_ACTION = "grant access →"
    public static let SETTINGS_LAST_DELIVERY_LABEL = "last added to your journal"
    public static let SETTINGS_LAST_DELIVERY_NEVER = "nothing added yet"
    public static let SETTINGS_LAST_DELIVERY_NOT_LINKED = "your journal isn't linked"
    public static let SETTINGS_DIAGNOSTICS_TITLE = "diagnostics"
    public static let SETTINGS_DIAGNOSTICS_INTRO = "a short summary for troubleshooting."
    public static let SETTINGS_DIAGNOSTICS_SHOW = "show diagnostics"
    public static let SETTINGS_DIAGNOSTICS_HIDE = "hide diagnostics"
    public static let SETTINGS_DIAGNOSTICS_COPY = "copy diagnostics"
    public static let SETTINGS_DIAGNOSTICS_COPIED = "copied"
    public static let SETTINGS_DIAGNOSTICS_COPY_ANNOUNCEMENT = "diagnostics copied to the clipboard"
    public static let SETTINGS_DIAGNOSTICS_COPY_FAILED = "couldn't copy diagnostics"
    public static let SETTINGS_DIAGNOSTICS_CHECKED_AT = "checked at"
    public static let SETTINGS_DIAGNOSTICS_APP_VERSION = "app version"
    public static let SETTINGS_DIAGNOSTICS_SCREEN_RECORDING = "screen recording"
    public static let SETTINGS_DIAGNOSTICS_MICROPHONE = "microphone"
    public static let SETTINGS_DIAGNOSTICS_SCREEN_AND_AUDIO = "sources"
    public static let SETTINGS_DIAGNOSTICS_LAST_JOURNAL_CONNECTION = "last journal connection"
    public static let SETTINGS_DIAGNOSTICS_INGEST_REASON = "journal intake"
    public static let SETTINGS_DIAGNOSTICS_INGEST_ROUTE = "journal intake address"
    public static let SETTINGS_DIAGNOSTICS_JOURNAL_LINK = "journal link"
    public static let SETTINGS_DIAGNOSTICS_NO_LINK_REFUSALS = "nothing turned away or ended early"
    public static func diagnosticsStreamLimitRefused(count: Int, last: String) -> String {
        "your journal turned away \(count) requests at its limit · last \(last)"
    }
    // ⛔ Never "lost the connection": this line exists only because the journal
    // sent a reset, which it can only do over a live link. Saying the
    // connection dropped would print the misleading symptom back as the
    // diagnosis, which is the failure this row was added to end.
    public static func diagnosticsStreamDropped(count: Int, last: String) -> String {
        "your journal ended \(count) requests early · last \(last)"
    }
    public static let SETTINGS_DIAGNOSTICS_RECENT_STATE_CODES = "recent state codes"
    public static let SETTINGS_DIAGNOSTICS_GRANTED = "granted"
    public static let SETTINGS_DIAGNOSTICS_NOT_GRANTED = "not granted"
    public static let SETTINGS_DIAGNOSTICS_CHECKING = "checking"
    public static let SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK = "couldn't check"
    public static let SETTINGS_DIAGNOSTICS_ON = "on"
    public static let SETTINGS_DIAGNOSTICS_PAUSED = "paused"
    public static let SETTINGS_DIAGNOSTICS_OFF = "off"
    public static let SETTINGS_DIAGNOSTICS_ERROR = "error"
    public static let SETTINGS_DIAGNOSTICS_NO_CONNECTION = "no connection yet"
    public static let SETTINGS_DIAGNOSTICS_NO_RECENT_CODES = "no recent state codes"
    public static let JOURNAL_ADDRESSES_LABEL = "addresses"
    public static let JOURNAL_RELAY_LABEL = "relay"
    public static let JOURNAL_RELAY_OFF = "off"
    public static func journalRelayOn(host: String) -> String {
        "on \u{00B7} \(host)"
    }
    public static let JOURNAL_CONNECTED_THROUGH_LABEL = "connected through"
    public static let JOURNAL_CONNECTED_THROUGH_RELAY = "the relay"
    public static let JOURNAL_ADDRESSES_TRIED_LABEL = "addresses tried"
    /// `tried A` · `tried A and B` · `tried A, B and C`
    public static func journalTriedAddresses(_ addresses: [String]) -> String? {
        guard let last = addresses.last else { return nil }
        guard addresses.count > 1 else { return "tried \(last)" }
        return "tried \(addresses.dropLast().joined(separator: ", ")) and \(last)"
    }
    public static let SETTINGS_PERMISSIONS_SCREEN_RECORDING_RESET_HINT = "if solstone is already in Applications but doesn't appear in Screen & System Audio Recording, remove any old solstone entry and try enabling screen recording again."
    public static let SETTINGS_NEXT_GRANT_PERMISSIONS = "next: grant permissions →"
    public static let SETTINGS_PERMISSIONS_SCREEN_EXPLAINER = "macOS lists this as Screen & System Audio Recording. grant it so what you share can go into your journal."
    public static let SETTINGS_PERMISSIONS_MIC_EXPLAINER = "macOS lists this as Microphone. grant it so what you share can go into your journal."
    public static let SETTINGS_PERMISSIONS_MIC_DENIED = "microphone access is off. allow solstone in Privacy & Security → Microphone."
    public static let SETTINGS_PERMISSIONS_MIC_RESTRICTED = "microphone access is restricted by this mac."
    public static let SETTINGS_PERMISSIONS_OPEN_SYSTEM_SETTINGS = "open system settings →"
    public static let SETTINGS_HELP_ICON_RECORDING = "on · reaching your journal"
    public static let SETTINGS_HELP_ICON_CONNECTING = "connecting"
    public static let SETTINGS_HELP_ICON_PAUSED = "paused, or both sources off"
    public static let SETTINGS_HELP_ICON_ATTENTION = "needs your attention"
    public static let SETTINGS_HELP_ICON_OFFLINE = "on · saved on this mac, not reaching your journal right now"
    public static let SETTINGS_HELP_ICON_ERROR = "something's broken"
    public static let SETTINGS_LOG_EXPORT_TITLE = "recent logs"
    public static let SETTINGS_LOG_EXPORT_INTRO = "read up to the last 24 hours of logs from solstone on this mac. save a copy if you want one."
    public static let SETTINGS_LOG_EXPORT_ACTION = "show recent logs"
    public static let SETTINGS_LOG_EXPORT_WORKING = "reading recent logs…"
    public static let SETTINGS_LOG_EXPORT_SAVE = "save a copy…"
    public static let SETTINGS_LOG_EXPORT_FAILED = "couldn't read recent logs"
    public static let SETTINGS_LOG_EXPORT_PARTIAL = "some logs couldn't be read"
    public static let SETTINGS_LOG_EXPORT_EMPTY = "no logs in the last 24 hours"
    public static let SETTINGS_LOG_EXPORT_WRITE_FAILED = "couldn't save the copy"
    public static let SETTINGS_LOG_EXPORT_PREVIEW_SUBSET = "showing the newest %d of %d entries. saving writes all of them."
    // The status card names the same state the help legend names, in the same words,
    // so the red dot and its explanation cannot drift apart.
    public static let STATUS_CAPTURE_ERROR_TITLE = "something's broken"
    public static let ERROR_LOGIN_ITEM = "couldn't update your login setting. try again, or toggle it off and on."
    public static let ERROR_SAVE_CONFIG = "couldn't save your settings. try again, or restart solstone."
    public static let ERROR_START_OBSERVING = "couldn't turn intake on. check permissions in settings, then try again."

    public static func menubarErrorOpenSettings(_ message: String) -> String {
        "error: \(message) →"
    }

    public static func settingsSetupVerdictNeedsAttention(_ count: Int) -> String {
        count == 1 ? "1 thing needs attention" : "\(count) things need attention"
    }

}
