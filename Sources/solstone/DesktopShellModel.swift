// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import UpdateKit

// The window, the menu bar panel and the native menu all draw the same five sources from
// these derivations. Nothing here reads app state: callers pass plain facts in, so every
// rule below can be tested without the app running.

/// The sources this Mac has, in tile order.
enum DeckSource: String, CaseIterable, Hashable, Sendable {
    case audio, screen, terminal, browsers, obsidian, screenshots

    var label: String {
        switch self {
        case .audio: return MacStrings.macos_desktopshellmodel_audio()
        case .screen: return MacStrings.macos_setupscreenframe_screen()
        case .terminal: return MacStrings.macos_ui_terminal()
        case .browsers: return MacStrings.macos_ui_browsers()
        case .obsidian: return MacStrings.macos_ui_obsidian()
        case .screenshots: return ScreenshotCopy.label
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "waveform"
        case .screen: return "display"
        case .terminal: return "apple.terminal"
        case .browsers: return "globe"
        case .obsidian: return "diamond"
        case .screenshots: return "photo"
        }
    }

    /// The legacy settings tab whose body a page now shows, for `markSettingsTabVisited`.
    var visitedTabName: String {
        switch self {
        case .audio: return "microphones"
        case .screen: return "privacy"
        case .terminal, .browsers, .obsidian, .screenshots: return "sources"
        }
    }

    /// The sources a build can show. Browser intake exists only when it is compiled in.
    static var available: [DeckSource] {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        return allCases
#else
        return allCases.filter { $0 != .browsers }
#endif
    }
}

/// The seven state words, shared with every other solstone app.
enum DeckStateWord: String, Equatable, Sendable, CaseIterable {
    case off, on, paused, settingUp, readyToSetUp, checking, needsAttention

    var word: String {
        switch self {
        case .off: return MacStrings.macos_desktop_shared_app_microphonemodeoff()
        case .on: return MacStrings.macos_desktop_shared_app_settingsdiagnosticson()
        case .paused: return MacStrings.macos_ui_paused()
        case .settingUp: return MacStrings.macos_desktopshellmodel_settingup()
        case .readyToSetUp: return MacStrings.macos_desktopshellmodel_readytosetup()
        case .checking: return MacStrings.macos_screenshot_checking()
        case .needsAttention: return MacStrings.macos_desktop_shared_copy_settingstabattentiona11y()
        }
    }

    var axToken: String {
        switch self {
        case .off: return "off"
        case .on: return "on"
        case .paused: return "paused"
        case .settingUp: return "setting_up"
        case .readyToSetUp: return "ready_to_set_up"
        case .checking: return "checking"
        case .needsAttention: return "needs_attention"
        }
    }
}

/// The one thing a source's reason row can do.
enum DeckSourceAction: Equatable, Sendable {
    case openMicrophoneSettings
    case askMicrophone
    case openScreenRecordingSettings
    case askScreenRecording
    case restartApp
    case tryAgain
    case chooseVault
    case openSafariSettings
    case allowScreenshotFolder
    case openScreenshotSettings
    case retryScreenshotCount
    case resumeIntake
}

struct DeckTile: Equatable, Sendable {
    var source: DeckSource
    var state: DeckStateWord
    /// Drawn under the state word. Nil when the state word says it all.
    var subline: String?
    /// The page's reason row: plain words, and one action where an action can help.
    var reason: String?
    var action: DeckSourceAction?
    /// Nil when the source has no switch here.
    var switchOn: Bool?

    /// What VoiceOver reads after the name: the state word, then a reason the word doesn't carry.
    var accessibilityValue: String {
        if state == .needsAttention, let subline { return "\(state.word). \(subline)" }
        if state == .paused, let subline { return "\(state.word). \(subline)" }
        return state.word
    }
}

enum DeckCopy {
    static let offPaired = MacStrings.macos_desktopshellmodel_turnitonanytime()
    static let offUnpaired = MacStrings.macos_desktopshellmodel_turnitonanytime()
    static let screenWithActivity = MacStrings.macos_desktopshellmodel_withcomputersoundandactivity()
    static let screenWithoutActivity = MacStrings.macos_desktopshellmodel_withcomputersound()
    static let activityStillOn = MacStrings.macos_desktopshellmodel_activityisstillon()
    static let microphoneDenied = MacStrings.macos_desktopshellmodel_microphoneaccessisoffforthesolstoneapp()
    static let microphoneRestricted = MacStrings.macos_copy_settingspermissionsmicrestricted()
    static let microphoneNeeded = MacStrings.macos_desktopshellmodel_thesolstoneappneedsmicrophoneaccess()
    static let screenDenied = MacStrings.macos_desktopshellmodel_screenrecordingisoffforthesolstoneapp()
    static let screenNeeded = MacStrings.macos_desktopshellmodel_thesolstoneappneedsscreenrecordingaccess()
    static let screenStopped = MacStrings.macos_desktopshellmodel_ascreenisntcomingthrough()
    static let screenCouldNotStart = MacStrings.macos_desktopshellmodel_ascreencouldntstart()
    static let tmuxMissing = MacStrings.macos_desktopshellmodel_tmuxisntinstalled()
    static let chooseVault = MacStrings.macos_desktopshellmodel_chooseavaulttostart()
    static let protectedVideo = MacStrings.macos_copy_settingsobservationprotectedvideo()
    static let onThisDevice = MacStrings.macos_desktopstatuspane_onthisdevice()
    static let notReachingJournal = MacStrings.macos_desktopshellmodel_notreachingyourjournalrightnow()

    static let audioTakesIn = MacStrings.macos_desktopshellmodel_whilethisisonthesolstoneapptakesinsoundfromyo()
    static let screenTakesIn = MacStrings.macos_desktopshellmodel_whilethisisonthesolstoneapptakesinwhatsonyour()
    static let terminalTakesIn = MacStrings.macos_desktopshellmodel_thesolstoneapptakesinyourtmuxsessionsandallof()
    static let browsersSetUp = MacStrings.macos_desktopshellmodel_addthesolstoneextensiontoabrowseronthismac()
    static let browsersNeedJournal = MacStrings.macos_desktopshellmodel_browserpagesstartonceyoupairthismacwithajourn()
    static let browsersTakesIn = MacStrings.macos_desktopshellmodel_onthesitesyouallowthesolstoneextensiontakesin()
}

// MARK: - inputs

enum DeckMicrophoneAccess: Equatable, Sendable {
    case granted, notAsked, denied, restricted, unknown
}

enum DeckScreenAccess: Equatable, Sendable {
    case granted, notAsked, denied, needsRestart
}

/// Where the media session stands for one media source, from `permissionSourceLiveState`.
enum DeckMediaLive: Equatable, Sendable {
    case on, ownerPaused, protectedVideo, notRunning
}

enum DeckTerminalState: Equatable, Sendable {
    case unknown, off, paused, tmuxNotFound, oldAppInstalled, running, restarting
}

enum DeckObsidianState: Equatable, Sendable {
    case unknown, off, on, paused, waitingForJournalUpdate, needsAttention
}

enum DeckBrowserState: Equatable, Sendable {
    /// Intake is on and able to run: taking pages in from any browser that sends them.
    case running(connected: [String])
    case starting
    case checking
    case paused
    case notPaired
    case fault(String)
}

struct DeckInputs: Equatable, Sendable {
    var paired = true
    var ownerPaused = false

    var microphoneOn = true
    var microphoneAccess: DeckMicrophoneAccess = .granted
    var microphoneLive: DeckMediaLive = .on

    var screenOn = true
    var screenAccess: DeckScreenAccess = .granted
    var screenLive: DeckMediaLive = .on
    var screenFailure: ScreenFailureKind?
    var activityEnabled = true
    /// Activity is going into the journal right now.
    var activityGoingIn = true
    var activityFailed = false
    var activityFailedLine = MacStrings.macos_desktopshellmodel_activitycouldntbesavedcheckfreespaceonthismac()
    var privateWindowsNeedAttention = false
    var privateWindowsLine = ""

    /// The media pipeline's own error, which belongs to every media source switched on.
    var captureError: String?

    var terminalOn = false
    var terminalState: DeckTerminalState = .off
    var terminalProblem: String?

    var browsersOn = true
    var browserState: DeckBrowserState = .running(connected: [])

    var obsidianState: DeckObsidianState = .off
    var obsidianVaultName: String?
    var obsidianAttentionLine: String?

    var screenshot = ScreenshotSnapshot.notSetUp
}

extension DeckInputs {
    func declarations(vaultConfirmed: Bool, browserConfigured: Bool, permissionsChecked: Bool) -> [SourceDeclaration] {
        DeckSource.allCases.compactMap { source in
            switch source {
            case .obsidian: guard vaultConfirmed else { return nil }
            case .screenshots: guard screenshot.configuredForDeclaration else { return nil }
            case .audio: guard microphoneOn && permissionsChecked else { return nil }
            case .screen: guard screenOn && permissionsChecked else { return nil }
            case .browsers: guard browsersOn && browserConfigured else { return nil }
            case .terminal: guard terminalOn else { return nil }
            }
            let state: String
            switch deriveDeckTile(source, self).state {
            case .on: state = "on"
            case .paused: state = "paused"
            case .needsAttention: state = "needs_attention"
            default: return nil
            }
            var row = SourceDeclaration(source: source.rawValue, state: state)
            if source == .obsidian, let name = obsidianVaultName,
               name.utf8.count <= 256, name.rangeOfCharacter(from: .controlCharacters) == nil,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                row.detail = name
            }
            return row
        }
    }
}

// MARK: - tiles

func deriveDeckTile(_ source: DeckSource, _ i: DeckInputs) -> DeckTile {
    switch source {
    case .audio: return deriveAudioTile(i)
    case .screen: return deriveScreenTile(i)
    case .terminal: return deriveTerminalTile(i)
    case .browsers: return deriveBrowsersTile(i)
    case .obsidian: return deriveObsidianTile(i)
    case .screenshots: return deriveScreenshotTile(i)
    }
}

private func deriveScreenshotTile(_ i: DeckInputs) -> DeckTile {
    let shot = i.screenshot
    return DeckTile(
        source: .screenshots, state: shot.state, subline: shot.subline,
        reason: shot.reason, action: shot.action, switchOn: shot.switchOn
    )
}

func deriveDeck(_ i: DeckInputs, sources: [DeckSource] = DeckSource.available) -> [DeckTile] {
    sources.map { deriveDeckTile($0, i) }
}

private func offTile(_ source: DeckSource, _ i: DeckInputs, subline: String? = nil) -> DeckTile {
    let line = i.paired ? DeckCopy.offPaired : DeckCopy.offUnpaired
    return DeckTile(source: source, state: .off, subline: subline ?? line, reason: line, action: nil, switchOn: false)
}

private func deriveAudioTile(_ i: DeckInputs) -> DeckTile {
    guard i.microphoneOn else { return offTile(.audio, i) }
    switch i.microphoneAccess {
    case .denied:
        return DeckTile(source: .audio, state: .needsAttention, subline: DeckCopy.microphoneDenied, reason: DeckCopy.microphoneDenied, action: .openMicrophoneSettings, switchOn: true)
    case .restricted:
        return DeckTile(source: .audio, state: .needsAttention, subline: DeckCopy.microphoneRestricted, reason: DeckCopy.microphoneRestricted, action: nil, switchOn: true)
    case .notAsked:
        return DeckTile(source: .audio, state: .readyToSetUp, subline: nil, reason: DeckCopy.microphoneNeeded, action: .askMicrophone, switchOn: true)
    case .unknown:
        return DeckTile(source: .audio, state: .checking, subline: nil, reason: nil, action: nil, switchOn: true)
    case .granted:
        break
    }
    if let error = i.captureError {
        return DeckTile(source: .audio, state: .needsAttention, subline: error, reason: error, action: .tryAgain, switchOn: true)
    }
    switch i.microphoneLive {
    case .protectedVideo:
        return DeckTile(source: .audio, state: .paused, subline: DeckCopy.protectedVideo, reason: DeckCopy.protectedVideo, action: nil, switchOn: true)
    case .ownerPaused:
        // The window's header says how long is left and holds resume, so the tile keeps its own line.
        return DeckTile(source: .audio, state: .paused, subline: nil, reason: nil, action: nil, switchOn: true)
    case .on:
        return DeckTile(source: .audio, state: .on, subline: nil, reason: nil, action: nil, switchOn: true)
    case .notRunning:
        if i.ownerPaused {
            return DeckTile(source: .audio, state: .paused, subline: nil, reason: nil, action: nil, switchOn: true)
        }
        return DeckTile(source: .audio, state: .settingUp, subline: nil, reason: nil, action: nil, switchOn: true)
    }
}

private func deriveScreenTile(_ i: DeckInputs) -> DeckTile {
    let activityLine: String? = i.activityGoingIn && i.activityEnabled ? DeckCopy.activityStillOn : nil
    let ownLine = i.activityEnabled ? DeckCopy.screenWithActivity : DeckCopy.screenWithoutActivity
    guard i.screenOn else {
        // Off never hides a fault in an intake still running under the tile.
        if activityLine != nil, i.activityFailed {
            return DeckTile(source: .screen, state: .needsAttention, subline: i.activityFailedLine, reason: i.activityFailedLine, action: nil, switchOn: false)
        }
        if i.privateWindowsNeedAttention {
            return DeckTile(source: .screen, state: .needsAttention, subline: i.privateWindowsLine, reason: i.privateWindowsLine, action: nil, switchOn: false)
        }
        return offTile(.screen, i, subline: activityLine)
    }
    switch i.screenAccess {
    case .denied:
        return DeckTile(source: .screen, state: .needsAttention, subline: DeckCopy.screenDenied, reason: DeckCopy.screenDenied, action: .openScreenRecordingSettings, switchOn: true)
    case .needsRestart:
        let line = MacStrings.macos_copy_sourcesrestartready()
        return DeckTile(source: .screen, state: .needsAttention, subline: line, reason: line, action: .restartApp, switchOn: true)
    case .notAsked:
        return DeckTile(source: .screen, state: .readyToSetUp, subline: nil, reason: DeckCopy.screenNeeded, action: .askScreenRecording, switchOn: true)
    case .granted:
        break
    }
    if let error = i.captureError {
        return DeckTile(source: .screen, state: .needsAttention, subline: error, reason: error, action: .tryAgain, switchOn: true)
    }
    if let failure = i.screenFailure {
        let line = failure == .couldNotStart ? DeckCopy.screenCouldNotStart : DeckCopy.screenStopped
        return DeckTile(source: .screen, state: .needsAttention, subline: line, reason: line, action: .tryAgain, switchOn: true)
    }
    if i.activityFailed {
        return DeckTile(source: .screen, state: .needsAttention, subline: i.activityFailedLine, reason: i.activityFailedLine, action: nil, switchOn: true)
    }
    if i.privateWindowsNeedAttention {
        return DeckTile(source: .screen, state: .needsAttention, subline: i.privateWindowsLine, reason: i.privateWindowsLine, action: nil, switchOn: true)
    }
    switch i.screenLive {
    case .protectedVideo:
        return DeckTile(source: .screen, state: .paused, subline: activityLine ?? DeckCopy.protectedVideo, reason: DeckCopy.protectedVideo, action: nil, switchOn: true)
    case .ownerPaused:
        return DeckTile(source: .screen, state: .paused, subline: activityLine ?? ownLine, reason: nil, action: nil, switchOn: true)
    case .on:
        return DeckTile(source: .screen, state: .on, subline: ownLine, reason: nil, action: nil, switchOn: true)
    case .notRunning:
        if i.ownerPaused {
            return DeckTile(source: .screen, state: .paused, subline: activityLine ?? ownLine, reason: nil, action: nil, switchOn: true)
        }
        return DeckTile(source: .screen, state: .settingUp, subline: nil, reason: nil, action: nil, switchOn: true)
    }
}

private func deriveTerminalTile(_ i: DeckInputs) -> DeckTile {
    guard i.terminalOn else { return offTile(.terminal, i) }
    if let problem = i.terminalProblem {
        return DeckTile(source: .terminal, state: .needsAttention, subline: problem, reason: problem, action: nil, switchOn: true)
    }
    switch i.terminalState {
    case .tmuxNotFound:
        return DeckTile(source: .terminal, state: .needsAttention, subline: DeckCopy.tmuxMissing, reason: DeckCopy.tmuxMissing, action: nil, switchOn: true)
    case .oldAppInstalled:
        let line = MacStrings.macos_ui_solstonefortmuxis()
        return DeckTile(source: .terminal, state: .needsAttention, subline: line, reason: line, action: nil, switchOn: true)
    case .paused:
        return DeckTile(source: .terminal, state: .paused, subline: nil, reason: nil, action: nil, switchOn: true)
    case .running:
        return DeckTile(source: .terminal, state: .on, subline: nil, reason: nil, action: nil, switchOn: true)
    case .restarting:
        return DeckTile(source: .terminal, state: .settingUp, subline: nil, reason: nil, action: nil, switchOn: true)
    case .unknown, .off:
        return DeckTile(source: .terminal, state: .checking, subline: nil, reason: nil, action: nil, switchOn: true)
    }
}

private func deriveBrowsersTile(_ i: DeckInputs) -> DeckTile {
    guard i.browsersOn else { return offTile(.browsers, i) }
    switch i.browserState {
    case .fault(let line):
        return DeckTile(source: .browsers, state: .needsAttention, subline: line, reason: line, action: nil, switchOn: true)
    case .paused:
        return DeckTile(source: .browsers, state: .paused, subline: nil, reason: nil, action: nil, switchOn: true)
    case .notPaired:
        return DeckTile(source: .browsers, state: .readyToSetUp, subline: nil, reason: DeckCopy.browsersNeedJournal, action: nil, switchOn: true)
    case .starting:
        return DeckTile(source: .browsers, state: .settingUp, subline: nil, reason: nil, action: nil, switchOn: true)
    case .running(let connected):
        let formatter = ListFormatter()
        if MacStrings.language != "en-US" { formatter.locale = Locale(identifier: MacStrings.language) }
        let line = connected.isEmpty ? nil : formatter.string(from: connected)
        return DeckTile(source: .browsers, state: .on, subline: line, reason: nil, action: nil, switchOn: true)
    case .checking:
        return DeckTile(source: .browsers, state: .checking, subline: nil, reason: nil, action: nil, switchOn: true)
    }
}

/// A pause reaches only a browser source that is running. One waiting to be set up, or one with a
/// fault, keeps its word through the pause.
func deckBrowserStatePausing(_ state: DeckBrowserState, ownerPaused: Bool) -> DeckBrowserState {
    guard ownerPaused else { return state }
    switch state {
    case .running, .starting, .checking: return .paused
    case .paused, .notPaired, .fault: return state
    }
}

private func deriveObsidianTile(_ i: DeckInputs) -> DeckTile {
    switch i.obsidianState {
    case .off, .unknown:
        return DeckTile(source: .obsidian, state: .off, subline: i.paired ? DeckCopy.offPaired : DeckCopy.offUnpaired, reason: DeckCopy.chooseVault, action: .chooseVault, switchOn: false)
    case .needsAttention:
        let line = i.obsidianAttentionLine ?? MacStrings.macos_ui_somenotescouldnt()
        return DeckTile(source: .obsidian, state: .needsAttention, subline: line, reason: line, action: nil, switchOn: true)
    case .paused:
        let line = MacStrings.macos_ui_obsidianispausedyour()
        return DeckTile(source: .obsidian, state: .paused, subline: i.obsidianVaultName, reason: line, action: nil, switchOn: true)
    case .waitingForJournalUpdate:
        let line = MacStrings.macos_ui_waitingforajournal()
        return DeckTile(source: .obsidian, state: .settingUp, subline: line, reason: line, action: nil, switchOn: true)
    case .on:
        return DeckTile(source: .obsidian, state: .on, subline: i.obsidianVaultName, reason: nil, action: nil, switchOn: true)
    }
}

/// Whether any tile (including import) says `needs attention`, for the menu bar icon: the one
/// place a fault rolls up. `ready to review` is non-fault and never rolls up here.
func deckHasFault(_ tiles: [DeckTile], importHasFault: Bool = false) -> Bool {
    importHasFault || tiles.contains { $0.state == .needsAttention }
}

// MARK: - deck keyboard focus

enum DeckTileFocus: Hashable, Sendable {
    case source(DeckSource)
    case importTile
}

enum DeckFocusDirection: Equatable, Sendable {
    case left, right, up, down
}

func moveDeckTileFocus(
    from current: DeckTileFocus?,
    direction: DeckFocusDirection,
    order: [DeckTileFocus],
    columns: Int
) -> DeckTileFocus? {
    guard !order.isEmpty else { return nil }
    guard let current, let index = order.firstIndex(of: current) else { return order.first }
    let next: Int
    switch direction {
    case .left: next = index - 1
    case .right: next = index + 1
    case .up: next = index - columns
    case .down: next = index + columns
    }
    return order.indices.contains(next) ? order[next] : current
}

// MARK: - import tile

enum ImportTileState: String, CaseIterable, Equatable, Sendable {
    case idle
    case waiting
    case paused
    case sending
    case readyToReview
    case needsAttention

    var axToken: String {
        switch self {
        case .idle: return "idle"
        case .waiting: return "waiting"
        case .paused: return "paused"
        case .sending: return "sending"
        case .readyToReview: return "ready_to_review"
        case .needsAttention: return "needs_attention"
        }
    }

    var word: String? {
        switch self {
        case .idle: return nil
        case .waiting: return ImportCopy.waiting
        case .paused: return ImportCopy.paused
        case .sending: return ImportCopy.sending
        case .readyToReview: return ImportCopy.readyToReview
        case .needsAttention: return DeckStateWord.needsAttention.word
        }
    }
}

struct ImportTilePresentation: Equatable, Sendable {
    var state: ImportTileState
    /// Optional override for the visible status label (e.g. `checking file` during whole-file check).
    var statusLabel: String? = nil
    var subline: String

    var displayedWord: String? { statusLabel ?? state.word }

    var accessibilityValue: String {
        if let word = displayedWord {
            return MacStrings.macos_desktopimportpage_tilevalue(word, subline)
        }
        return subline
    }
}

/// Worst-signal-wins derivation for the home `import` tile:
/// `needs attention` > `ready to review` > `sending` > `paused` > `waiting` > calm idle (`files`).
func deriveImportTile(_ snapshot: ImportSnapshot) -> ImportTilePresentation {
    if snapshot.storeUnreadable {
        return ImportTilePresentation(state: .needsAttention, subline: ImportCopy.tileSubline)
    }
    let faultRows = snapshot.rows.filter { row in
        switch row.kind {
        case .refused, .missingCopy: return true
        case .waiting, .sending, .paused, .goingAgain, .readyToReview, .reviewExpired: return false
        }
    }
    if !faultRows.isEmpty {
        let subline = faultRows.count == 1
            ? faultRows[0].name
            : MacStrings.macos_desktopimportpage_tileitems_plural(faultRows.count)
        return ImportTilePresentation(state: .needsAttention, subline: subline)
    }
    if snapshot.waiting == .journalTooOld && !snapshot.rows.isEmpty {
        let subline = snapshot.rows.count == 1
            ? snapshot.rows[0].name
            : MacStrings.macos_desktopimportpage_tileitems_plural(snapshot.rows.count)
        return ImportTilePresentation(state: .needsAttention, subline: subline)
    }
    let reviewRows = snapshot.reviewRows
    if !reviewRows.isEmpty {
        let subline = reviewRows.count == 1
            ? reviewRows[0].name
            : MacStrings.macos_desktopimportpage_tileready_plural(reviewRows.count)
        return ImportTilePresentation(state: .readyToReview, subline: subline)
    }
    let sendingRows = snapshot.rows.filter { $0.kind == .sending }
    if !sendingRows.isEmpty {
        if let activeResumable = sendingRows.first(where: { $0.progress != nil }),
           let progress = activeResumable.progress {
            if progress.phase == .checking {
                let subline = sendingRows.count == 1
                    ? activeResumable.name
                    : MacStrings.macos_desktopimportpage_tilefiles_plural(sendingRows.count)
                return ImportTilePresentation(state: .sending, statusLabel: ImportCopy.checkingFile, subline: subline)
            }
            let queuedBehind = snapshot.rows.filter {
                $0.kind == .waiting || $0.kind == .paused || $0.kind == .goingAgain
            }.count + max(0, sendingRows.count - 1)
            let sent = importFormatBytes(progress.bytesSent)
            let total = importFormatBytes(progress.bytesTotal)
            let subline = queuedBehind > 0
                ? ImportCopy.tileProgressMore(count: queuedBehind, sent: sent, total: total)
                : ImportCopy.tileProgress(sent: sent, total: total)
            return ImportTilePresentation(state: .sending, subline: subline)
        }
        let subline = sendingRows.count == 1
            ? sendingRows[0].name
            : MacStrings.macos_desktopimportpage_tilefiles_plural(sendingRows.count)
        return ImportTilePresentation(state: .sending, subline: subline)
    }
    let pausedRows = snapshot.rows.filter { $0.kind == .paused }
    if !pausedRows.isEmpty {
        if let first = pausedRows.first(where: { $0.progress != nil }),
           let progress = first.progress {
            let moreWaiting = max(0, pausedRows.count - 1)
                + snapshot.rows.filter { $0.kind == .waiting || $0.kind == .goingAgain }.count
            let sent = importFormatBytes(progress.bytesSent)
            let total = importFormatBytes(progress.bytesTotal)
            let subline = moreWaiting > 0
                ? ImportCopy.tileProgressMore(count: moreWaiting, sent: sent, total: total)
                : ImportCopy.tileProgress(sent: sent, total: total)
            return ImportTilePresentation(state: .paused, subline: subline)
        }
        return ImportTilePresentation(state: .paused, subline: pausedRows[0].name)
    }
    let waitingRows = snapshot.rows.filter { $0.kind == .waiting || $0.kind == .goingAgain }
    if !waitingRows.isEmpty {
        let heldForJournal = snapshot.offline
            || snapshot.waiting == .unpaired
            || snapshot.waiting == .awaitingConfirmation
            || snapshot.waiting == .pairingRefused
        let subline = heldForJournal
            ? ImportCopy.tileWaitingForJournal
            : MacStrings.macos_desktopimportpage_tilewaiting_plural(waitingRows.count)
        return ImportTilePresentation(state: .waiting, subline: subline)
    }
    return ImportTilePresentation(state: .idle, subline: ImportCopy.tileSubline)
}

// MARK: - the journal pill

/// Why everything left on this Mac waits on the owner rather than on a sync.
enum JournalHeld: Equatable, Sendable {
    /// Imports here that won't go on their own: each one needs the owner, or the journal needs an update.
    case importsNeedYou
    /// Segments the journal answered it would not write.
    case segmentsNotWritten
}

enum JournalPill: Equatable, Sendable {
    case needsNewLink
    case notPaired
    case confirmMark(waiting: Int)
    case syncPaused(waiting: Int)
    case pairAgain(waiting: Int)
    case offline(waiting: Int)
    case connecting
    case syncing(Int)
    /// A finished pass left segments that will go on their own later.
    case waiting(Int)
    case waitingToSync
    /// Connected, with nothing waiting to sync and 0 faults, while 1+ imports await owner review.
    case readyToReview(Int)
    case connected
    /// Connected, with nothing waiting to sync, but something here that waits on the owner.
    case connectedHeld(JournalHeld)

    var text: String {
        switch self {
        case .needsNewLink: return MacStrings.macos_app_yourjournalneedsanewlink()
        case .notPaired: return MacStrings.macos_desktop_shared_app_notpaired()
        case .confirmMark(let n): return n > 0 ? MacStrings.macos_desktopshellmodel_confirmthemarkwaiting("\(n)") : MacStrings.macos_desktopstatuspane_confirmthemark()
        case .syncPaused(let n): return n > 0 ? MacStrings.macos_desktopshellmodel_syncpausedwaiting("\(n)") : MacStrings.macos_app_syncpaused()
        case .pairAgain(let n): return n > 0 ? MacStrings.macos_desktopshellmodel_pairagainwaiting("\(n)") : MacStrings.macos_desktopshellmodel_pairagain()
        case .offline(let n): return MacStrings.macos_desktopshellmodel_offlinewaiting("\(n)")
        case .connecting: return MacStrings.macos_desktopstatuspane_connecting()
        case .syncing(let n): return MacStrings.macos_desktopshellmodel_syncing("\(n)")
        case .waiting(let n): return MacStrings.macos_desktopshellmodel_waiting("\(n)")
        case .waitingToSync: return MacStrings.macos_desktopstatuspane_waitingtosync()
        case .readyToReview(let n): return MacStrings.macos_desktopimportpage_pillready_plural(n)
        case .connected, .connectedHeld: return MacStrings.macos_desktopshellmodel_connected()
        }
    }

    /// Green only when the last sync pass said everything reached the journal.
    var isCaughtUp: Bool { self == .connected }

    var waiting: Int {
        switch self {
        case .confirmMark(let n), .syncPaused(let n), .pairAgain(let n), .offline(let n), .syncing(let n), .waiting(let n): return n
        case .needsNewLink, .notPaired, .connecting, .waitingToSync, .readyToReview, .connected, .connectedHeld: return 0
        }
    }

    var axToken: String {
        switch self {
        case .needsNewLink: return "needs_new_link"
        case .notPaired: return "not_paired"
        case .confirmMark: return "confirm_mark"
        case .syncPaused: return "sync_paused"
        case .pairAgain: return "pair_again"
        case .offline: return "offline"
        case .connecting: return "connecting"
        case .syncing: return "syncing"
        case .waiting: return "waiting"
        case .waitingToSync: return "waiting_to_sync"
        case .readyToReview: return "ready_to_review"
        case .connected: return "connected"
        case .connectedHeld: return "connected_held"
        }
    }
}

/// The journal's reachability as `classifyJournalConnection` reads it, the same reading the icon uses.
enum DeckConnection: Equatable, Sendable {
    case reachable, waiting, offline, blocked
}

/// Where the last sync pass stands.
enum DeckUploadPhase: Equatable, Sendable {
    case starting, sending, synced
}

struct JournalPillInputs: Equatable, Sendable {
    var bundledService = false
    var hasJournal = true
    var markHeld = false
    var syncPaused = false
    /// The journal refuses this pairing (revoked, mismatch, not entitled): a retry won't help.
    var pairingRefused = false
    var connection: DeckConnection = .reachable
    var upload: DeckUploadPhase = .synced
    var pending = 0
    /// Set when something on this Mac waits on the owner, so the pill never reads caught up.
    var held: JournalHeld?
    /// Imports awaiting owner preview & confirmation in the journal (non-fault).
    var readyToReview = 0
}

func deriveJournalPill(_ i: JournalPillInputs) -> JournalPill {
    if i.bundledService { return .needsNewLink }
    if !i.hasJournal { return .notPaired }
    if i.markHeld { return .confirmMark(waiting: i.pending) }
    if i.syncPaused { return .syncPaused(waiting: i.pending) }
    if i.pairingRefused { return .pairAgain(waiting: i.pending) }
    switch i.connection {
    case .waiting: return .connecting
    case .offline, .blocked: return .offline(waiting: i.pending)
    case .reachable: break
    }
    switch i.upload {
    case .starting: return .connecting
    case .sending: return i.pending > 0 ? .syncing(i.pending) : .waitingToSync
    case .synced:
        if i.pending > 0 { return .waiting(i.pending) }
        if let held = i.held { return .connectedHeld(held) }
        if i.readyToReview > 0 { return .readyToReview(i.readyToReview) }
        return .connected
    }
}

/// The status pane's `connection` fact. Offline says it in the words every computer uses; any other
/// state keeps the connection's own line.
func statusConnectionValue(_ pill: JournalPill, connectionLine: String) -> String {
    if case .offline = pill { return DeckCopy.notReachingJournal }
    return connectionLine
}

/// Reads the connection the way the icon does.
func deckConnection(_ row: MenubarStatusRowState) -> DeckConnection {
    switch row {
    case .connectionWaiting: return .waiting
    case .offline: return .offline
    case .error: return .blocked
    default: return .reachable
    }
}

func deckUploadPhase(_ status: UploadCoordinator.Status) -> DeckUploadPhase {
    switch status {
    case .notSynced, .awaitingTunnel: return .starting
    case .syncing, .uploading, .retrying, .offline, .blocked: return .sending
    case .synced: return .synced
    }
}

// MARK: - small pieces

/// The greeting bands every solstone app shares.
func deckGreeting(forHour hour: Int) -> String {
    switch hour {
    case 5...11: return MacStrings.macos_desktopshellmodel_goodmorning()
    case 12...16: return MacStrings.macos_desktopshellmodel_goodafternoon()
    default: return MacStrings.macos_desktopshellmodel_goodevening()
    }
}


/// The header line while paused. Nil when nothing is paused.
func pausedTimeLeftLine(isPaused: Bool, remaining: TimeInterval?) -> String? {
    guard isPaused else { return nil }
    guard let remaining else { return MacStrings.macos_desktopshellmodel_pauseduntilyouresume() }
    if remaining < 60 { return MacStrings.macos_desktopshellmodel_pausedlessthanaminuteleft() }
    let minutes = Int((remaining / 60).rounded(.up))
    if minutes < 60 { return MacStrings.macos_desktopshellmodel_pausedminleft(MacStrings.number(minutes)) }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? MacStrings.macos_pause_deckhours(hours) : MacStrings.macos_pause_deckhoursminutes(hours, String(rest))
}

// MARK: - what a source has taken in

struct SourceTotalFacts: Equatable, Sendable {
    /// `so far`'s value.
    var soFar: String
    var totalOnly: String? = nil
    /// `last taken in`'s value; nil while nothing has been taken in.
    var lastTakenIn: String?
}

enum SourceTotalUnit: Sendable {
    case seconds, pages, notes, screenshots, items
}

/// The words for one source's total, or nil when the record can't be read (the rows are then absent).
func sourceTotalFacts(
    _ view: SourceTotals.View?,
    source: DeckSource,
    now: Date,
    calendar: Calendar = .current
) -> SourceTotalFacts? {
    guard let view else { return nil }
    let amount: Int, started: String, last: String?, unit: SourceTotalUnit
    switch source {
    case .audio: (amount, started, last, unit) = (view.audioSeconds, view.audioStarted, view.audioLast, .seconds)
    case .screen: (amount, started, last, unit) = (view.screenSeconds, view.screenStarted, view.screenLast, .seconds)
    case .terminal: (amount, started, last, unit) = (view.terminalSeconds, view.terminalStarted, view.terminalLast, .seconds)
    case .browsers: (amount, started, last, unit) = (view.browsersTotal, view.browsersStarted, view.browsersLast, .pages)
    case .obsidian: (amount, started, last, unit) = (view.obsidianTotal, view.obsidianStarted, view.obsidianLast, .notes)
    case .screenshots: (amount, started, last, unit) = (view.screenshotsTotal, view.screenshotsStarted, view.screenshotsLast, .screenshots)
    }
    let lastDate = last.flatMap(SourceTotals.parseInstant)
    guard amount > 0 || lastDate != nil else {
        return SourceTotalFacts(soFar: MacStrings.macos_desktopshellmodel_nothingyet(), lastTakenIn: nil)
    }
    let startedText = startedWords(started, now: now, calendar: calendar)
    let total = totalWords(amount, unit: unit)
    return SourceTotalFacts(
        soFar: startedText.map { MacStrings.macos_desktopshellmodel_since(total, "\($0)") } ?? total,
        totalOnly: total,
        lastTakenIn: lastDate.map { relativeWords($0, now: now, calendar: calendar) }
    )
}

func totalWords(_ amount: Int, unit: SourceTotalUnit) -> String {
    let grouped = { (n: Int) -> String in
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
    switch unit {
    case .seconds:
        if amount < 60 { return MacStrings.macos_desktopshellmodel_lessthanaminute() }
        if amount < 3600 {
            let minutes = amount / 60
            return MacStrings.macos_desktopshellmodel_minutes_plural(minutes, "\(grouped(minutes))")
        }
        let hours = amount / 3600
        return MacStrings.macos_source_hours(hours, grouped(hours))
    case .pages:
        return MacStrings.macos_desktopshellmodel_pages_plural(amount, "\(grouped(amount))")
    case .notes:
        return MacStrings.macos_desktopshellmodel_notes_plural(amount, "\(grouped(amount))")
    case .screenshots:
        return ScreenshotCopy.total(amount)
    case .items:
        return MacStrings.macos_desktopshellmodel_items_plural(amount, "\(grouped(amount))")
    }
}

/// Lifetime `so far` and `last taken in` facts for the import pane, or nil when unreadable.
func importTotalFacts(
    _ view: SourceTotals.View?,
    now: Date,
    calendar: Calendar = .current
) -> SourceTotalFacts? {
    guard let view else { return nil }
    let lastDate = view.importsLast.flatMap(SourceTotals.parseInstant)
    guard view.importsTotal > 0 || lastDate != nil else {
        return SourceTotalFacts(soFar: MacStrings.macos_desktopshellmodel_nothingyet(), lastTakenIn: nil)
    }
    let startedText = startedWords(view.importsStarted, now: now, calendar: calendar)
    let total = totalWords(view.importsTotal, unit: .items)
    return SourceTotalFacts(
        soFar: startedText.map { MacStrings.macos_desktopshellmodel_since(total, "\($0)") } ?? total,
        totalOnly: total,
        lastTakenIn: lastDate.map { relativeWords($0, now: now, calendar: calendar) }
    )
}

private func startedWords(_ day: String, now: Date, calendar: Calendar) -> String? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
        return nil
    }
    return monthDayWords(date, now: now, calendar: calendar)
}

private func monthDayWords(_ date: Date, now: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: MacStrings.language)
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "yMMMMd")
    return formatter.string(from: date).lowercased(with: formatter.locale)
}

func relativeWords(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return MacStrings.macos_desktop_shared_app_justnow() }
    if seconds < 3600 { return MacStrings.macos_desktopshellmodel_minago(MacStrings.number(Int(seconds / 60))) }
    if calendar.isDate(date, inSameDayAs: now) {
        let hours = Int(seconds / 3600)
        return MacStrings.macos_desktopshellmodel_hoursago_plural(hours)
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
        return MacStrings.macos_desktopshellmodel_yesterday()
    }
    return monthDayWords(date, now: now, calendar: calendar)
}

// MARK: - widths

/// The window at three widths, like the devices: the iPad split with its shelf, the split with
/// the shelf tucked behind a button, and one column that pushes like the iPhone.
enum ShellLayout: Equatable, Sendable {
    case full, narrow, phone

    static let fullMinimum: CGFloat = 1120
    static let narrowMinimum: CGFloat = 720

    init(width: CGFloat) {
        if width >= Self.fullMinimum { self = .full }
        else if width >= Self.narrowMinimum { self = .narrow }
        else { self = .phone }
    }

    /// The deck's columns depend on the width alone, never on what the pane shows.
    var deckColumns: Int { self == .full ? 3 : 2 }
    var paneWidth: CGFloat { self == .full ? 400 : 340 }
}

/// The status pane's per-source row: `so far` and `last taken in`, or `nothing yet` across both.
struct SourceTotalColumns: Equatable, Sendable {
    var soFar: String
    var lastTakenIn: String?
}

func sourceTotalColumns(_ view: SourceTotals.View?, source: DeckSource, now: Date, calendar: Calendar = .current) -> SourceTotalColumns? {
    guard let facts = sourceTotalFacts(view, source: source, now: now, calendar: calendar) else { return nil }
    return SourceTotalColumns(soFar: facts.totalOnly ?? facts.soFar, lastTakenIn: facts.lastTakenIn)
}

// MARK: - the menu bar menu

/// The menu's words for the update the icon's dot is about: one that is downloaded and installs
/// at quit, one that is found but not downloaded yet, or a check that failed.
enum ShellMenuUpdateNotice: Equatable, Sendable {
    case ready
    case available
    case checkFailed

    init?(_ status: DurableUpdateStatus) {
        switch status {
        case .staged: self = .ready
        case .available, .deferred, .failedWithAvailable: self = .available
        case .failed: self = .checkFailed
        case .upToDate, .idle: return nil
        }
    }
}

/// One row of the menu bar menu, top to bottom.
enum ShellMenuRow: Equatable, Sendable {
    case attention(DeckSource)
    case importAttention
    case update(ShellMenuUpdateNotice)
    case checkForUpdates
    case status(String)
    case pause
    case resume
    case divider
    case openSettings
    case openJournal(enabled: Bool)
    case about
    case quit

    var title: String {
        switch self {
        case .attention(let source): return MacStrings.macos_desktopshellmodel_needsattention("\(source.label)")
        case .importAttention: return MacStrings.macos_desktopshellmodel_needsattention("\(ImportCopy.title)")
        case .update(.ready): return MacStrings.macos_desktopshellmodel_updateready()
        case .update(.available): return MacStrings.macos_copy_settingsattentionupdateavailable()
        case .update(.checkFailed): return MacStrings.macos_copy_settingsattentionupdatecheckfailed()
        case .checkForUpdates: return MacStrings.macos_desktopshellmodel_checkforupdates()
        case .status(let line): return line
        case .pause: return MacStrings.macos_desktop_shared_setup_wizardpausefailure()
        case .resume: return MacStrings.macos_desktop_shared_setup_wizardpausefailure2()
        case .divider: return ""
        case .openSettings: return MacStrings.macos_desktopshellmodel_opensettings()
        case .openJournal: return MacStrings.macos_desktop_shared_copy_settingsjournalopen()
        case .about: return MacStrings.macos_desktop_shared_app_aboutsolstone()
        case .quit: return MacStrings.macos_menu_quitsolstone()
        }
    }
}

/// The menu's rows from the deck, the pill, the pause state and the update. No source rows
/// except a fault, and no switches: the window is where sources are turned on and off. An update
/// the icon's dot is about is named under the faults, because the shelf row that carries its
/// badge is hidden below full width; with none waiting, `check for updates…` sits by `about`.
func shellMenuRows(
    tiles: [DeckTile],
    pill: JournalPill,
    pausedLine: String?,
    canPause: Bool,
    canResume: Bool,
    hasJournal: Bool,
    canOpenJournal: Bool,
    update: DurableUpdateStatus = .idle,
    importHasFault: Bool = false
) -> [ShellMenuRow] {
    var rows: [ShellMenuRow] = tiles.filter { $0.state == .needsAttention }.map { .attention($0.source) }
    if importHasFault { rows.append(.importAttention) }
    let notice = ShellMenuUpdateNotice(update)
    if let notice { rows.append(.update(notice)) }
    rows.append(.status(pausedLine ?? menuStatusLine(pill)))
    if canPause { rows.append(.pause) } else if canResume { rows.append(.resume) }
    rows.append(.divider)
    rows.append(.openSettings)
    if hasJournal { rows.append(.openJournal(enabled: canOpenJournal)) }
    rows.append(contentsOf: [.divider, .about])
    if notice == nil { rows.append(.checkForUpdates) }
    rows.append(contentsOf: [.divider, .quit])
    return rows
}

// MARK: - status rows

/// The status pane's row for one source, always present: the total and the time, or `nothing yet`
/// under `so far` with `last taken in` empty, whether or not the record could be read.
func statusSourceRow(_ view: SourceTotals.View?, source: DeckSource, now: Date, calendar: Calendar = .current) -> SourceTotalColumns {
    sourceTotalColumns(view, source: source, now: now, calendar: calendar) ?? SourceTotalColumns(soFar: MacStrings.macos_desktopshellmodel_nothingyet(), lastTakenIn: nil)
}
