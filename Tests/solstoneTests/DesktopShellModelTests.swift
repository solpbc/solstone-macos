// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Desktop shell model")
struct DesktopShellModelTests {
    // MARK: tiles

    @Test func everySourceIsOnWhenItsSessionRuns() {
        var inputs = DeckInputs()
        inputs.terminalOn = true
        inputs.terminalState = .running
        inputs.obsidianState = .on
        inputs.obsidianVaultName = "field notes"
        inputs.screenshot = .running(folderLine: "Desktop")
        inputs.browserState = .running(connected: ["Chrome", "Safari"])
        for tile in deriveDeck(inputs, sources: DeckSource.allCases) {
            #expect(tile.state == .on, "\(tile.source)")
        }
        #expect(deriveDeckTile(.obsidian, inputs).subline == "field notes")
    }

    @Test func aSwitchedOffSourceStaysOffThroughAPause() {
        var inputs = DeckInputs()
        inputs.ownerPaused = true
        inputs.microphoneOn = false
        inputs.screenOn = false
        inputs.browsersOn = false
        inputs.activityEnabled = false
        inputs.microphoneLive = .ownerPaused
        inputs.screenLive = .ownerPaused
        inputs.browserState = .paused
        for source in [DeckSource.audio, .screen, .browsers] {
            #expect(deriveDeckTile(source, inputs).state == .off, "\(source)")
        }
    }

    @Test func aSwitchedOnSourceIsPausedThroughAPause() {
        var inputs = DeckInputs()
        inputs.ownerPaused = true
        inputs.microphoneLive = .ownerPaused
        inputs.screenLive = .ownerPaused
        inputs.activityGoingIn = false
        inputs.browserState = .paused
        for source in [DeckSource.audio, .screen, .browsers] {
            #expect(deriveDeckTile(source, inputs).state == .paused, "\(source)")
        }
    }

    @Test func aPausedTileKeepsItsOwnSubLine() {
        var inputs = DeckInputs()
        inputs.ownerPaused = true
        inputs.microphoneLive = .ownerPaused
        inputs.screenLive = .ownerPaused
        inputs.activityGoingIn = false
        inputs.terminalOn = true
        inputs.terminalState = .paused
        inputs.browserState = .paused
        inputs.obsidianState = .paused
        inputs.obsidianVaultName = "field notes"
        let tiles = deriveDeck(inputs, sources: [.audio, .screen, .terminal, .browsers, .obsidian])
        for tile in tiles {
            #expect(tile.state == .paused, "\(tile.source)")
            #expect(!(tile.subline ?? "").contains("intake"), "\(tile.source)")
            #expect(!(tile.subline ?? "").contains("you paused this"), "\(tile.source)")
        }
        #expect(deriveDeckTile(.screen, inputs).subline == DeckCopy.screenWithActivity)
        #expect(deriveDeckTile(.audio, inputs).subline == nil)
        #expect(deriveDeckTile(.obsidian, inputs).subline == "field notes")
        inputs.activityEnabled = false
        #expect(deriveDeckTile(.screen, inputs).subline == DeckCopy.screenWithoutActivity)

        // Activity kept on through the pause says so, because it really is still going in.
        inputs.activityEnabled = true
        inputs.activityGoingIn = true
        #expect(deriveDeckTile(.screen, inputs).subline == DeckCopy.activityStillOn)
    }

    @Test func aPauseReachesOnlyARunningBrowserSource() {
        #expect(deckBrowserStatePausing(.running(connected: ["Chrome"]), ownerPaused: true) == .paused)
        #expect(deckBrowserStatePausing(.starting, ownerPaused: true) == .paused)
        #expect(deckBrowserStatePausing(.notPaired, ownerPaused: true) == .notPaired)
        #expect(deckBrowserStatePausing(.fault("x"), ownerPaused: true) == .fault("x"))
        #expect(deckBrowserStatePausing(.running(connected: []), ownerPaused: false) == .running(connected: []))

        var inputs = DeckInputs()
        inputs.ownerPaused = true
        inputs.browserState = deckBrowserStatePausing(.notPaired, ownerPaused: true)
        let tile = deriveDeckTile(.browsers, inputs)
        #expect(tile.state == .readyToSetUp)
        #expect(tile.reason == DeckCopy.browsersNeedJournal)
    }

    @Test func aNeverAskedMicrophoneTheOwnerSwitchedOffIsOff() {
        var inputs = DeckInputs()
        inputs.microphoneOn = false
        inputs.microphoneAccess = .notAsked
        #expect(deriveDeckTile(.audio, inputs).state == .off)
        inputs.microphoneOn = true
        let tile = deriveDeckTile(.audio, inputs)
        #expect(tile.state == .readyToSetUp)
        #expect(tile.subline == nil)
        #expect(tile.action == .askMicrophone)
    }

    @Test func aRestrictedMicrophoneOffersNoAction() {
        var inputs = DeckInputs()
        inputs.microphoneAccess = .restricted
        let tile = deriveDeckTile(.audio, inputs)
        #expect(tile.state == .needsAttention)
        #expect(tile.action == nil)
        inputs.microphoneAccess = .denied
        #expect(deriveDeckTile(.audio, inputs).action == .openMicrophoneSettings)
    }

    @Test func aCaptureErrorShowsOnEverySwitchedOnMediaTileWithTryAgain() {
        var inputs = DeckInputs()
        inputs.captureError = "the recorder stopped"
        for source in [DeckSource.audio, .screen] {
            let tile = deriveDeckTile(source, inputs)
            #expect(tile.state == .needsAttention)
            #expect(tile.reason == "the recorder stopped")
            #expect(tile.action == .tryAgain)
        }
        inputs.microphoneOn = false
        #expect(deriveDeckTile(.audio, inputs).state == .off)
        #expect(deriveDeckTile(.terminal, inputs).state == .off)
    }

    @Test func offNeverHidesAFaultStillRunningUnderTheTile() {
        var inputs = DeckInputs()
        inputs.screenOn = false
        inputs.activityGoingIn = true
        inputs.activityFailed = true
        #expect(deriveDeckTile(.screen, inputs).state == .needsAttention)
        inputs.activityFailed = false
        inputs.privateWindowsNeedAttention = true
        inputs.privateWindowsLine = "can't check private windows"
        #expect(deriveDeckTile(.screen, inputs).state == .needsAttention)
        inputs.privateWindowsNeedAttention = false
        #expect(deriveDeckTile(.screen, inputs).state == .off)
    }

    @Test func screenSaysWhenActivityIsStillGoingIn() {
        var inputs = DeckInputs()
        inputs.screenOn = false
        inputs.activityGoingIn = true
        #expect(deriveDeckTile(.screen, inputs).subline == DeckCopy.activityStillOn)
        inputs.activityGoingIn = false
        #expect(deriveDeckTile(.screen, inputs).subline != DeckCopy.activityStillOn)

        inputs.screenOn = true
        inputs.screenLive = .protectedVideo
        inputs.activityGoingIn = true
        let held = deriveDeckTile(.screen, inputs)
        #expect(held.state == .paused)
        #expect(held.subline == DeckCopy.activityStillOn)
    }

    @Test func screenNamesActivityOnlyWhileActivityIsOn() {
        var inputs = DeckInputs()
        #expect(deriveDeckTile(.screen, inputs).subline == DeckCopy.screenWithActivity)
        inputs.activityEnabled = false
        #expect(deriveDeckTile(.screen, inputs).subline == DeckCopy.screenWithoutActivity)
    }

    @Test func audioUnderProtectedVideoIsPausedWithItsOwnReason() {
        var inputs = DeckInputs()
        inputs.microphoneLive = .protectedVideo
        let tile = deriveDeckTile(.audio, inputs)
        #expect(tile.state == .paused)
        #expect(tile.subline == DeckCopy.protectedVideo)
    }

    @Test func browsersStayOnWithNoBrowserConnected() {
        var inputs = DeckInputs()
        inputs.browserState = .running(connected: [])
        let none = deriveDeckTile(.browsers, inputs)
        #expect(none.state == .on)
        #expect(none.subline == nil)
        inputs.browserState = .running(connected: ["Chrome"])
        #expect(deriveDeckTile(.browsers, inputs).state == none.state)
    }

    @Test func runningTerminalIsNeverOff() {
        var inputs = DeckInputs()
        inputs.microphoneOn = false
        inputs.screenOn = false
        inputs.browsersOn = false
        inputs.activityEnabled = false
        inputs.terminalOn = true
        inputs.terminalState = .running
        let tiles = deriveDeck(inputs, sources: DeckSource.allCases)
        #expect(tiles.first { $0.source == .terminal }?.state == .on)
        #expect(!deckHasFault(tiles))
    }

    @Test func obsidianOffOffersTheVaultChoiceNotASilentToggle() {
        let tile = deriveDeckTile(.obsidian, DeckInputs())
        #expect(tile.state == .off)
        #expect(tile.switchOn == false)
        #expect(tile.action == .chooseVault)
    }

    @Test func aFaultRaisesTheIconAndNothingElseDoes() {
        var inputs = DeckInputs()
        #expect(!deckHasFault(deriveDeck(inputs)))
        inputs.terminalOn = true
        inputs.terminalState = .tmuxNotFound
        #expect(deckHasFault(deriveDeck(inputs, sources: DeckSource.allCases)))
    }

    @Test func spokenValueIsTheStateWordPlusAReasonOnly() {
        var inputs = DeckInputs()
        #expect(deriveDeckTile(.screen, inputs).accessibilityValue == "on")
        inputs.screenAccess = .denied
        #expect(deriveDeckTile(.screen, inputs).accessibilityValue == "needs attention. \(DeckCopy.screenDenied)")
    }

    // MARK: pill

    @Test func offlineStatusReadsTheSharedWords() {
        let pill = deriveJournalPill(JournalPillInputs(connection: .offline, pending: 12))
        #expect(pill.text == "offline · 12 waiting")
        #expect(statusConnectionValue(pill, connectionLine: "connected to your journal") == "not reaching your journal right now")
        #expect(statusConnectionValue(.connected, connectionLine: "connected to your journal") == "connected to your journal")
    }

    @Test func pillStatesThatAreNotCaughtUpNeverReadConnected() {
        let cases: [JournalPillInputs] = [
            JournalPillInputs(bundledService: true),
            JournalPillInputs(hasJournal: false),
            JournalPillInputs(markHeld: true),
            JournalPillInputs(syncPaused: true),
            JournalPillInputs(pairingRefused: true),
            JournalPillInputs(connection: .waiting),
            JournalPillInputs(connection: .offline),
            JournalPillInputs(connection: .blocked),
            JournalPillInputs(upload: .starting),
            JournalPillInputs(upload: .sending),
            JournalPillInputs(pending: 3),
        ]
        for inputs in cases {
            let pill = deriveJournalPill(inputs)
            #expect(pill != .connected, "\(inputs)")
            #expect(!pill.isCaughtUp)
        }
        #expect(deriveJournalPill(JournalPillInputs()) == .connected)
    }

    @Test func pillReadsReachabilityTheWayTheIconDoes() {
        // The upload failed for a reason that is a drop of reachability: the icon keeps observing.
        let reachabilityDrop = classifyJournalConnection(
            isPairedIngestReady: true, presentedConnection: .connected,
            uploadStatus: .offline("x"), lastHealthReason: .uploadFailed
        )
        #expect(deckConnection(reachabilityDrop) == .reachable)
        // The journal answered and refused: offline.
        let refused = classifyJournalConnection(
            isPairedIngestReady: true, presentedConnection: .connected,
            uploadStatus: .offline("x"), lastHealthReason: .journalRefused(reasonCode: "x")
        )
        #expect(deriveJournalPill(JournalPillInputs(connection: deckConnection(refused))) == .offline(waiting: 0))
        // Presented connected, but this pairing is not admitted yet.
        let notReady = classifyJournalConnection(
            isPairedIngestReady: false, presentedConnection: .connected,
            uploadStatus: .synced, lastHealthReason: nil
        )
        #expect(deriveJournalPill(JournalPillInputs(connection: deckConnection(notReady))) != .connected)
        #expect(deckUploadPhase(.notSynced) == .starting)
    }

    @Test func aRefusedPairingSaysPairAgainNotOffline() {
        #expect(deriveJournalPill(JournalPillInputs(pairingRefused: true, connection: .offline, pending: 2)) == .pairAgain(waiting: 2))
    }

    @Test func pillCountsWhatIsWaiting() {
        #expect(deriveJournalPill(JournalPillInputs(connection: .offline, pending: 12)) == .offline(waiting: 12))
        #expect(deriveJournalPill(JournalPillInputs(upload: .sending, pending: 4)) == .syncing(4))
        #expect(deriveJournalPill(JournalPillInputs(upload: .sending)) == .waitingToSync)
    }

    @Test func aFinishedPassWithSegmentsLeftReadsWaitingNotSyncing() {
        #expect(deriveJournalPill(JournalPillInputs(pending: 3)) == .waiting(3))
        #expect(JournalPill.waiting(3).waiting == 3)
        #expect(!JournalPill.waiting(3).isCaughtUp)
    }

    @Test func somethingHeldForTheOwnerNeverReadsCaughtUp() {
        #expect(deriveJournalPill(JournalPillInputs(held: .segmentsNotWritten)) == .connectedHeld(.segmentsNotWritten))
        #expect(deriveJournalPill(JournalPillInputs()) == .connected)
        #expect(!JournalPill.connectedHeld(.segmentsNotWritten).isCaughtUp)
        #expect(JournalPill.connectedHeld(.segmentsNotWritten).axToken != JournalPill.connected.axToken)
        // Every earlier state wins over held.
        #expect(deriveJournalPill(JournalPillInputs(markHeld: true, held: .segmentsNotWritten)) == .confirmMark(waiting: 0))
        #expect(deriveJournalPill(JournalPillInputs(syncPaused: true, held: .segmentsNotWritten)) == .syncPaused(waiting: 0))
        #expect(deriveJournalPill(JournalPillInputs(pairingRefused: true, held: .segmentsNotWritten)) == .pairAgain(waiting: 0))
        #expect(deriveJournalPill(JournalPillInputs(connection: .offline, held: .segmentsNotWritten)) == .offline(waiting: 0))
        #expect(deriveJournalPill(JournalPillInputs(connection: .waiting, held: .segmentsNotWritten)) == .connecting)
        #expect(deriveJournalPill(JournalPillInputs(pending: 2, held: .segmentsNotWritten)) == .waiting(2))
    }

    @Test func everyPillTokenIsInTheAXContract() throws {
        let pills: [JournalPill] = [
            .needsNewLink, .notPaired, .confirmMark(waiting: 1), .syncPaused(waiting: 1), .pairAgain(waiting: 1),
            .offline(waiting: 1), .connecting, .syncing(1), .waiting(1), .waitingToSync, .connected,
            .connectedHeld(.segmentsNotWritten),
        ]
        let listed = try #require(AXContract.vocabularies["JournalPill"])
        for pill in pills { #expect(listed.contains(pill.axToken), "\(pill.axToken)") }
    }

    @Test func removeWaitsOnlyWhileAPassRuns() {
        #expect(unwrittenRemoveBlocked(status: .syncing(checked: 0, total: 1), syncPaused: false))
        #expect(unwrittenRemoveBlocked(status: .uploading(segment: "s"), syncPaused: false))
        #expect(unwrittenRemoveBlocked(status: .retrying(segment: "s", attempts: 1), syncPaused: false))
        for status: UploadCoordinator.Status in [.synced, .offline("x"), .blocked("x"), .awaitingTunnel, .notSynced] {
            #expect(!unwrittenRemoveBlocked(status: status, syncPaused: false))
        }
        #expect(!unwrittenRemoveBlocked(status: .uploading(segment: "s"), syncPaused: true))
    }

    @Test func aDeclinedSegmentIsNamedByItsStart() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let name = unwrittenSegmentName(UnwrittenSegment(day: "20261111", segment: "143000_300"), timeZone: utc)
        #expect(name.contains("2026"))
        #expect(name == name.lowercased())
        #expect(unwrittenSegmentName(UnwrittenSegment(day: "bad", segment: "143000_300")) == "143000_300")
    }

    // MARK: small pieces

    @Test func greetingBands() {
        #expect(deckGreeting(forHour: 5) == deckGreeting(forHour: 11))
        #expect(deckGreeting(forHour: 12) == deckGreeting(forHour: 16))
        #expect(deckGreeting(forHour: 4) == deckGreeting(forHour: 17))
        #expect(Set([deckGreeting(forHour: 9), deckGreeting(forHour: 14), deckGreeting(forHour: 20)]).count == 3)
    }

    @Test func widthsPickTheLayoutAndTheDeckNeverReflowsWithThePane() {
        #expect(ShellLayout(width: 1400) == .full)
        #expect(ShellLayout(width: ShellLayout.fullMinimum) == .full)
        #expect(ShellLayout(width: ShellLayout.fullMinimum - 1) == .narrow)
        #expect(ShellLayout(width: ShellLayout.narrowMinimum) == .narrow)
        #expect(ShellLayout(width: ShellLayout.narrowMinimum - 1) == .phone)
        #expect(ShellLayout.full.deckColumns == 3)
        #expect(ShellLayout.narrow.deckColumns == 2)
    }

    @Test func menuStatusLineAddsTheLeadOnlyWhenCaughtUp() {
        #expect(menuStatusLine(.connected) != JournalPill.connected.text)
        #expect(menuStatusLine(.connected).hasPrefix(JournalPill.connected.text))
        #expect(menuStatusLine(.offline(waiting: 12)) == JournalPill.offline(waiting: 12).text)
    }

    @Test func menuStatusLineSaysConnectedBeforeAWaitingCountAndNeverCaughtUpWhenHeld() {
        #expect(menuStatusLine(.waiting(3)).hasSuffix(JournalPill.waiting(3).text))
        #expect(menuStatusLine(.waiting(3)) != JournalPill.waiting(3).text)
        #expect(menuStatusLine(.waiting(3)).hasPrefix(JournalPill.connected.text))
        #expect(menuStatusLine(.connectedHeld(.segmentsNotWritten)) != menuStatusLine(.connected))
    }

    @Test func statusRowsCarryTheTotalAloneOrNothingYetAcross() throws {
        let now = try #require(SourceTotals.parseInstant("2026-11-10T15:00:00Z"))
        let row = try #require(sourceTotalColumns(view(audioSeconds: 7200, audioLast: "2026-11-10T12:00:00Z"), source: .audio, now: now, calendar: utc))
        #expect(!row.soFar.contains("since"))
        #expect(row.lastTakenIn != nil)
        let empty = try #require(sourceTotalColumns(view(), source: .audio, now: now, calendar: utc))
        #expect(empty.lastTakenIn == nil)
        #expect(sourceTotalColumns(nil, source: .audio, now: now) == nil)
    }

    @Test func timeLeftRoundsUpAndIndefiniteDiffers() throws {
        #expect(pausedTimeLeftLine(isPaused: false, remaining: 300) == nil)
        let fourteen = try #require(pausedTimeLeftLine(isPaused: true, remaining: 13 * 60 + 5))
        #expect(fourteen.contains("14"))
        let lastMinute = try #require(pausedTimeLeftLine(isPaused: true, remaining: 30))
        #expect(!lastMinute.contains("0"))
        let indefinite = try #require(pausedTimeLeftLine(isPaused: true, remaining: nil))
        #expect(indefinite != fourteen)
        #expect(indefinite.allSatisfy { !$0.isNumber })
    }

    // MARK: totals

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func view(audioSeconds: Int = 0, audioLast: String? = nil, started: String = "2026-03-03") -> SourceTotals.View {
        SourceTotals.View(
            audioSeconds: audioSeconds, audioRemainderMs: 0, audioLast: audioLast, audioSegments: [], audioStarted: started,
            screenSeconds: 0, screenRemainderMs: 0, screenLast: nil, screenSegments: [], screenStarted: started,
            terminalSeconds: 0, terminalLast: nil, terminalCarried: false, terminalStarted: started,
            browsersTotal: 1, browsersLast: nil, browsersTabs: [:], browsersStarted: started,
            obsidianTotal: 0, obsidianLast: nil, obsidianNotes: [], obsidianBaseline: true, obsidianStarted: started
        )
    }

    @Test func anUnreadableRecordHidesBothRows() {
        #expect(sourceTotalFacts(nil, source: .audio, now: Date(), calendar: utc) == nil)
    }

    @Test func nothingTakenInReadsNothingYetWithNoLastRow() throws {
        let facts = try #require(sourceTotalFacts(view(), source: .audio, now: Date(), calendar: utc))
        #expect(facts.lastTakenIn == nil)
        #expect(facts.soFar.allSatisfy { !$0.isNumber })
    }

    @Test func totalsCarryTheirStartAndLastTime() throws {
        let now = try #require(SourceTotals.parseInstant("2026-11-10T15:00:00Z"))
        let facts = try #require(sourceTotalFacts(
            view(audioSeconds: 2618 * 3600 + 5, audioLast: "2026-11-10T12:00:00Z"),
            source: .audio, now: now, calendar: utc
        ))
        #expect(facts.soFar.contains("2,618"))
        #expect(facts.soFar.contains("3"))
        #expect(facts.lastTakenIn?.contains("3") == true)
        #expect(totalWords(1, unit: .pages) != totalWords(2, unit: .pages).replacingOccurrences(of: "2", with: "1"))
        #expect(totalWords(40 * 60, unit: .seconds).contains("40"))
    }

    @Test func aStartFromAnotherYearCarriesItsYear() throws {
        let now = try #require(SourceTotals.parseInstant("2026-11-10T15:00:00Z"))
        let facts = try #require(sourceTotalFacts(view(audioSeconds: 7200, started: "2025-03-03"), source: .audio, now: now, calendar: utc))
        #expect(facts.soFar.contains("2025"))
    }

    // MARK: menu rows

    private func menu(_ tiles: [DeckTile], pill: JournalPill = .connected, paused: String? = nil,
                      canPause: Bool = true, canResume: Bool = false, hasJournal: Bool = true, canOpen: Bool = true) -> [ShellMenuRow] {
        shellMenuRows(tiles: tiles, pill: pill, pausedLine: paused, canPause: canPause, canResume: canResume,
                      hasJournal: hasJournal, canOpenJournal: canOpen)
    }

    @Test func menuLeadsWithEachSourceThatNeedsAttentionAndNamesNoOther() {
        var inputs = DeckInputs()
        inputs.screenAccess = .denied
        inputs.terminalOn = true
        inputs.terminalState = .tmuxNotFound
        let rows = menu(deriveDeck(inputs, sources: DeckSource.allCases))
        #expect(Array(rows.prefix(2)) == [.attention(.screen), .attention(.terminal)])
        #expect(rows.filter { if case .attention = $0 { return true } else { return false } }.count == 2)
        #expect(rows[2] == .status(menuStatusLine(.connected)))
        #expect(rows.contains(.pause))
        #expect(!rows.contains(.resume))
    }

    @Test func menuWithNothingWrongHasNoAttentionRows() {
        let rows = menu(deriveDeck(DeckInputs()))
        #expect(rows.first == .status(menuStatusLine(.connected)))
        #expect(rows.map(\.title) == [menuStatusLine(.connected), "pause", "", "open settings", "open journal", "", "about solstone", "", "quit solstone"])
    }

    @Test func pausedMenuShowsTheTimeLeftAndResumeInPlaceOfPause() throws {
        let line = try #require(pausedTimeLeftLine(isPaused: true, remaining: 14 * 60))
        let rows = menu(deriveDeck(DeckInputs()), paused: line, canPause: false, canResume: true)
        #expect(rows.first == .status(line))
        #expect(rows.contains(.resume))
        #expect(!rows.contains(.pause))
    }

    @Test func offlineMenuShowsThePillWordsAndAnUnreachableJournalIsDisabled() {
        let pill = JournalPill.offline(waiting: 12)
        let rows = menu(deriveDeck(DeckInputs()), pill: pill, canOpen: false)
        #expect(rows.first == .status(pill.text))
        #expect(rows.contains(.openJournal(enabled: false)))
    }

    @Test func unpairedMenuHasNoOpenJournal() {
        let rows = menu(deriveDeck(DeckInputs()), pill: .notPaired, hasJournal: false)
        #expect(!rows.contains { if case .openJournal = $0 { return true } else { return false } })
        #expect(rows.first == .status(JournalPill.notPaired.text))
    }

    @Test func statusRowPutsNothingYetUnderSoFarAndAlwaysExists() throws {
        let now = try #require(SourceTotals.parseInstant("2026-11-10T15:00:00Z"))
        let missing = statusSourceRow(nil, source: .terminal, now: now, calendar: utc)
        #expect(missing.lastTakenIn == nil)
        #expect(missing.soFar == statusSourceRow(view(), source: .audio, now: now, calendar: utc).soFar)
        let counted = statusSourceRow(view(audioSeconds: 7200, audioLast: "2026-11-10T14:56:00Z"), source: .audio, now: now, calendar: utc)
        #expect(counted.lastTakenIn != nil)
        #expect(counted.soFar != missing.soFar)
    }
}
