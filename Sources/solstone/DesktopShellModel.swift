// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

// The window, the menu bar panel and the native menu all draw the same five sources from
// these derivations. Nothing here reads app state: callers pass plain facts in, so every
// rule below can be tested without the app running.

/// The sources this Mac has, in tile order.
enum DeckSource: String, CaseIterable, Hashable, Sendable {
    case audio, screen, terminal, browsers, obsidian

    var label: String {
        switch self {
        case .audio: return "audio"
        case .screen: return "screen"
        case .terminal: return "terminal"
        case .browsers: return "browsers"
        case .obsidian: return "Obsidian"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "waveform"
        case .screen: return "display"
        case .terminal: return "apple.terminal"
        case .browsers: return "globe"
        case .obsidian: return "diamond"
        }
    }

    /// The legacy settings tab whose body a page now shows, for `markSettingsTabVisited`.
    var visitedTabName: String {
        switch self {
        case .audio: return "microphones"
        case .screen: return "privacy"
        case .terminal, .browsers, .obsidian: return "sources"
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
        case .off: return "off"
        case .on: return "on"
        case .paused: return "paused"
        case .settingUp: return "setting up"
        case .readyToSetUp: return "ready to set up"
        case .checking: return "checking…"
        case .needsAttention: return "needs attention"
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
        if state == .paused, let subline, subline != DeckCopy.ownerPaused { return "\(state.word). \(subline)" }
        return state.word
    }
}

enum DeckCopy {
    static let ownerPaused = "you paused this. resume to start intake again."
    static let offPaired = "intake is off. turn it on any time."
    static let offUnpaired = "turn it on any time."
    static let screenWithActivity = "with computer sound and activity"
    static let screenWithoutActivity = "with computer sound"
    static let activityStillOn = "activity is still on."
    static let microphoneDenied = "microphone access is off for the solstone app."
    static let microphoneRestricted = "microphone access is restricted by this mac."
    static let microphoneNeeded = "the solstone app needs microphone access."
    static let screenDenied = "screen recording is off for the solstone app."
    static let screenNeeded = "the solstone app needs screen recording access."
    static let screenStopped = "a screen isn't coming through."
    static let screenCouldNotStart = "a screen couldn't start."
    static let tmuxMissing = "tmux isn't installed."
    static let chooseVault = "choose a vault to start."
    static let protectedVideo = "paused for protected video"

    static let audioTakesIn = "while this is on, the solstone app takes in sound from your microphones, and all of it goes into your journal."
    static let screenTakesIn = "while this is on, the solstone app takes in what's on your screen, the sound your mac plays, and which apps and windows you're using, and all of it goes into your journal."
    static let terminalTakesIn = "the solstone app takes in your tmux sessions, and all of it goes into your journal. needs tmux on this mac, and works in any terminal session, including when you SSH into this mac."
    static let browsersTakesIn = "on the sites you allow, the solstone extension takes in the page's text and rough layout, and all of it goes into your journal."
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
    var activityFailedLine = "activity couldn't be saved. check free space on this mac."
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
}

// MARK: - tiles

func deriveDeckTile(_ source: DeckSource, _ i: DeckInputs) -> DeckTile {
    switch source {
    case .audio: return deriveAudioTile(i)
    case .screen: return deriveScreenTile(i)
    case .terminal: return deriveTerminalTile(i)
    case .browsers: return deriveBrowsersTile(i)
    case .obsidian: return deriveObsidianTile(i)
    }
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
        return DeckTile(source: .audio, state: .paused, subline: DeckCopy.ownerPaused, reason: DeckCopy.ownerPaused, action: nil, switchOn: true)
    case .on:
        return DeckTile(source: .audio, state: .on, subline: nil, reason: nil, action: nil, switchOn: true)
    case .notRunning:
        if i.ownerPaused {
            return DeckTile(source: .audio, state: .paused, subline: DeckCopy.ownerPaused, reason: DeckCopy.ownerPaused, action: nil, switchOn: true)
        }
        return DeckTile(source: .audio, state: .settingUp, subline: nil, reason: nil, action: nil, switchOn: true)
    }
}

private func deriveScreenTile(_ i: DeckInputs) -> DeckTile {
    let activityLine: String? = i.activityGoingIn && i.activityEnabled ? DeckCopy.activityStillOn : nil
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
        let line = "granted. solstone needs to restart before what's on your screen can go into your journal."
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
        return DeckTile(source: .screen, state: .paused, subline: activityLine ?? DeckCopy.ownerPaused, reason: DeckCopy.ownerPaused, action: nil, switchOn: true)
    case .on:
        return DeckTile(source: .screen, state: .on, subline: i.activityEnabled ? DeckCopy.screenWithActivity : DeckCopy.screenWithoutActivity, reason: nil, action: nil, switchOn: true)
    case .notRunning:
        if i.ownerPaused {
            return DeckTile(source: .screen, state: .paused, subline: activityLine ?? DeckCopy.ownerPaused, reason: DeckCopy.ownerPaused, action: nil, switchOn: true)
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
        let line = "solstone for tmux is still installed on this mac, so terminal stays off for now."
        return DeckTile(source: .terminal, state: .needsAttention, subline: line, reason: line, action: nil, switchOn: true)
    case .paused:
        return DeckTile(source: .terminal, state: .paused, subline: DeckCopy.ownerPaused, reason: DeckCopy.ownerPaused, action: nil, switchOn: true)
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
        return DeckTile(source: .browsers, state: .paused, subline: DeckCopy.ownerPaused, reason: DeckCopy.ownerPaused, action: nil, switchOn: true)
    case .notPaired:
        return DeckTile(source: .browsers, state: .readyToSetUp, subline: nil, reason: "browser pages can't start right now.", action: nil, switchOn: true)
    case .starting:
        return DeckTile(source: .browsers, state: .settingUp, subline: nil, reason: nil, action: nil, switchOn: true)
    case .running(let connected):
        let line = connected.isEmpty ? nil : ListFormatter.localizedString(byJoining: connected)
        return DeckTile(source: .browsers, state: .on, subline: line, reason: nil, action: nil, switchOn: true)
    case .checking:
        return DeckTile(source: .browsers, state: .checking, subline: nil, reason: nil, action: nil, switchOn: true)
    }
}

private func deriveObsidianTile(_ i: DeckInputs) -> DeckTile {
    switch i.obsidianState {
    case .off, .unknown:
        return DeckTile(source: .obsidian, state: .off, subline: i.paired ? DeckCopy.offPaired : DeckCopy.offUnpaired, reason: DeckCopy.chooseVault, action: .chooseVault, switchOn: false)
    case .needsAttention:
        let line = i.obsidianAttentionLine ?? "some notes couldn't go into your journal. the solstone app tries them again the next time it restarts."
        return DeckTile(source: .obsidian, state: .needsAttention, subline: line, reason: line, action: nil, switchOn: true)
    case .paused:
        let line = "Obsidian is paused. your notes wait on this mac."
        return DeckTile(source: .obsidian, state: .paused, subline: line, reason: line, action: nil, switchOn: true)
    case .waitingForJournalUpdate:
        let line = "waiting for a journal update. your notes wait on this mac."
        return DeckTile(source: .obsidian, state: .settingUp, subline: line, reason: line, action: nil, switchOn: true)
    case .on:
        return DeckTile(source: .obsidian, state: .on, subline: i.obsidianVaultName, reason: nil, action: nil, switchOn: true)
    }
}

/// Whether any tile says `needs attention`, for the menu bar icon: the one place a fault rolls up.
func deckHasFault(_ tiles: [DeckTile]) -> Bool {
    tiles.contains { $0.state == .needsAttention }
}

// MARK: - the journal pill

enum JournalPill: Equatable, Sendable {
    case needsNewLink
    case notPaired
    case confirmMark(waiting: Int)
    case syncPaused(waiting: Int)
    case pairAgain(waiting: Int)
    case offline(waiting: Int)
    case connecting
    case syncing(Int)
    case waitingToSync
    case connected

    var text: String {
        switch self {
        case .needsNewLink: return "your journal needs a new link"
        case .notPaired: return "not paired"
        case .confirmMark(let n): return n > 0 ? "confirm the mark · \(n) waiting" : "confirm the mark"
        case .syncPaused(let n): return n > 0 ? "sync paused · \(n) waiting" : "sync paused"
        case .pairAgain(let n): return n > 0 ? "pair again · \(n) waiting" : "pair again"
        case .offline(let n): return "offline · \(n) waiting"
        case .connecting: return "connecting…"
        case .syncing(let n): return "\(n) syncing"
        case .waitingToSync: return "waiting to sync"
        case .connected: return "connected"
        }
    }

    /// Green only when the last sync pass said everything reached the journal.
    var isCaughtUp: Bool { self == .connected }

    var waiting: Int {
        switch self {
        case .confirmMark(let n), .syncPaused(let n), .pairAgain(let n), .offline(let n), .syncing(let n): return n
        case .needsNewLink, .notPaired, .connecting, .waitingToSync, .connected: return 0
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
        case .waitingToSync: return "waiting_to_sync"
        case .connected: return "connected"
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
    case .synced: return i.pending > 0 ? .syncing(i.pending) : .connected
    }
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
    case 5...11: return "good morning"
    case 12...16: return "good afternoon"
    default: return "good evening"
    }
}

/// Three columns with nothing selected, two while a pane is open.
func deckColumns(paneOpen: Bool) -> Int { paneOpen ? 2 : 3 }

/// The header line while paused. Nil when nothing is paused.
func pausedTimeLeftLine(isPaused: Bool, remaining: TimeInterval?) -> String? {
    guard isPaused else { return nil }
    guard let remaining else { return "paused until you resume" }
    if remaining < 60 { return "paused, less than a minute left" }
    let minutes = Int((remaining / 60).rounded(.up))
    if minutes < 60 { return "paused, \(minutes) min left" }
    let hours = minutes / 60
    let rest = minutes % 60
    let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
    return rest == 0 ? "paused, \(hourText) left" : "paused, \(hourText) \(rest) min left"
}

// MARK: - what a source has taken in

struct SourceTotalFacts: Equatable, Sendable {
    /// `so far`'s value.
    var soFar: String
    /// `last taken in`'s value; nil while nothing has been taken in.
    var lastTakenIn: String?
}

enum SourceTotalUnit: Sendable {
    case seconds, pages, notes
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
    }
    let lastDate = last.flatMap(SourceTotals.parseInstant)
    guard amount > 0 || lastDate != nil else {
        return SourceTotalFacts(soFar: "nothing yet", lastTakenIn: nil)
    }
    let startedText = startedWords(started, now: now, calendar: calendar)
    let total = totalWords(amount, unit: unit)
    return SourceTotalFacts(
        soFar: startedText.map { "\(total), since \($0)" } ?? total,
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
        if amount < 60 { return "less than a minute" }
        if amount < 3600 {
            let minutes = amount / 60
            return minutes == 1 ? "1 minute" : "\(grouped(minutes)) minutes"
        }
        let hours = amount / 3600
        return hours == 1 ? "1 hour" : "\(grouped(hours)) hours"
    case .pages:
        return amount == 1 ? "1 page" : "\(grouped(amount)) pages"
    case .notes:
        return amount == 1 ? "1 note" : "\(grouped(amount)) notes"
    }
}

private func startedWords(_ day: String, now: Date, calendar: Calendar) -> String? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
        return nil
    }
    return monthDayWords(date, now: now, calendar: calendar)
}

private func monthDayWords(_ date: Date, now: Date, calendar: Calendar) -> String {
    let month = calendar.monthSymbols[calendar.component(.month, from: date) - 1].lowercased()
    let day = calendar.component(.day, from: date)
    let year = calendar.component(.year, from: date)
    return year == calendar.component(.year, from: now) ? "\(month) \(day)" : "\(month) \(day), \(year)"
}

func relativeWords(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
    if calendar.isDate(date, inSameDayAs: now) {
        let hours = Int(seconds / 3600)
        return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
        return "yesterday"
    }
    return monthDayWords(date, now: now, calendar: calendar)
}
