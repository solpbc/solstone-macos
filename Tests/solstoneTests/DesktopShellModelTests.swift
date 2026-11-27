// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import UpdateKit
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
            .offline(waiting: 1), .connecting, .syncing(1), .waiting(1), .waitingToSync, .readyToReview(1), .connected,
            .connectedHeld(.segmentsNotWritten),
        ]
        let listed = try #require(AXContract.vocabularies["JournalPill"])
        for pill in pills { #expect(listed.contains(pill.axToken), "\(pill.axToken)") }

        let tileListed = try #require(AXContract.vocabularies["ImportTileState"])
        for state in ImportTileState.allCases {
            #expect(tileListed.contains(state.axToken), "\(state.axToken)")
        }
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
                      canPause: Bool = true, canResume: Bool = false, hasJournal: Bool = true, canOpen: Bool = true,
                      update: DurableUpdateStatus = .upToDate) -> [ShellMenuRow] {
        shellMenuRows(tiles: tiles, pill: pill, pausedLine: paused, canPause: canPause, canResume: canResume,
                      hasJournal: hasJournal, canOpenJournal: canOpen, update: update)
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
        #expect(rows.map(\.title) == [menuStatusLine(.connected), "pause", "", "open settings", "open journal", "", "about solstone", ShellMenuRow.checkForUpdates.title, "", "quit solstone"])
    }

    @Test func aStagedUpdateIsNamedUnderTheFaultsAndTakesTheCheckRowsPlace() {
        var inputs = DeckInputs()
        inputs.screenAccess = .denied
        let rows = menu(deriveDeck(inputs, sources: DeckSource.allCases), update: .staged(version: "2.0.70", releaseNotes: nil))
        #expect(Array(rows.prefix(3)) == [.attention(.screen), .update(.ready), .status(menuStatusLine(.connected))])
        #expect(!rows.contains(.checkForUpdates))
    }

    @Test func withNoUpdateWaitingTheCheckRowSitsUnderAbout() throws {
        for status in [DurableUpdateStatus.upToDate, .idle] {
            let rows = menu(deriveDeck(DeckInputs()), update: status)
            let about = try #require(rows.firstIndex(of: .about))
            #expect(rows[about + 1] == .checkForUpdates)
            #expect(!rows.contains { if case .update = $0 { return true } else { return false } })
        }
    }

    @Test func eachUpdateStateTheIconBadgesHasWordsInTheMenu() {
        let statuses: [DurableUpdateStatus] = [
            .deferred(version: "2.0.70"), .staged(version: "2.0.70", releaseNotes: nil),
            .failedWithAvailable(version: "2.0.70"), .available(version: "2.0.70", releaseNotes: nil),
            .failed, .upToDate, .idle,
        ]
        for status in statuses {
            // The icon's dot and the updates row's badge come from this one reason; the menu must name it too.
            let badged = updateAttentionReason(for: status) != nil
            #expect((ShellMenuUpdateNotice(status) != nil) == badged)
            #expect((updatesSidebarBadge(for: status) == .attention) == badged)
        }
        #expect(ShellMenuUpdateNotice(.available(version: "2.0.70", releaseNotes: nil)) == .available)
        #expect(ShellMenuUpdateNotice(.deferred(version: "2.0.70")) == .available)
        #expect(ShellMenuUpdateNotice(.failed) == .checkFailed)
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

    // MARK: import tile, review pill, and import totals

    @Test func importTileWorstSignalWinsAndPreservesCalmIdle() {
        var s = ImportSnapshot()
        let idle = deriveImportTile(s)
        #expect(idle.state == .idle)
        #expect(idle.subline == "files")
        #expect(idle.accessibilityValue == "files")

        // Waiting while paired & online vs offline/unpaired
        s.waiting = .waiting
        s.rows = [ImportRow(id: "w1", name: "a.pdf", kind: .waiting, retryable: false, savedAtJournal: false)]
        let waitingOnline = deriveImportTile(s)
        #expect(waitingOnline.state == .waiting)
        #expect(waitingOnline.subline == "1 waiting")
        #expect(waitingOnline.accessibilityValue == "waiting. 1 waiting.")

        s.offline = true
        #expect(deriveImportTile(s).subline == "waiting for your journal")
        s.offline = false
        s.waiting = .unpaired
        #expect(deriveImportTile(s).subline == "waiting for your journal")
        s.waiting = .waiting

        // Sending outranks waiting
        s.rows.append(ImportRow(id: "s1", name: "notes.txt", kind: .sending, retryable: false, savedAtJournal: false))
        let sendingOne = deriveImportTile(s)
        #expect(sendingOne.state == .sending)
        #expect(sendingOne.subline == "notes.txt")

        s.rows.append(ImportRow(id: "s2", name: "photo.jpg", kind: .sending, retryable: false, savedAtJournal: false))
        #expect(deriveImportTile(s).subline == "2 files")

        // Ready to review outranks sending & waiting
        s.rows.append(ImportRow(id: "r1", name: "export.zip", kind: .readyToReview, retryable: false, savedAtJournal: true, importID: "20261122_140000"))
        let reviewOne = deriveImportTile(s)
        #expect(reviewOne.state == .readyToReview)
        #expect(reviewOne.subline == "export.zip")
        #expect(reviewOne.accessibilityValue == "ready to review. export.zip.")

        s.rows.append(ImportRow(id: "r2", name: "archive.zip", kind: .reviewExpired, retryable: true, savedAtJournal: false, importID: "20261122_140100", reviewExpired: true))
        #expect(deriveImportTile(s).subline == "2 ready in your journal")

        // Needs attention outranks ready to review
        s.rows.append(ImportRow(id: "f1", name: "broken.bin", kind: .refused("not supported"), retryable: false, savedAtJournal: false))
        let faultOne = deriveImportTile(s)
        #expect(faultOne.state == .needsAttention)
        #expect(faultOne.subline == "broken.bin")

        s.rows.append(ImportRow(id: "f2", name: "lost.jpg", kind: .missingCopy, retryable: false, savedAtJournal: false))
        #expect(deriveImportTile(s).subline == "2 items")

        // Unreadable store always needs attention
        var unreadable = ImportSnapshot()
        unreadable.storeUnreadable = true
        #expect(deriveImportTile(unreadable).state == .needsAttention)
    }

    @Test func importTileShowsResumableProgressCheckingAndPausedWithWorstSignalPriority() {
        let fourGiB: Int64 = 4 * 1024 * 1024 * 1024
        let onePointTwoGiB: Int64 = 1_288_490_188

        // Active resumable sending (single file) -> "sending" + "1.2 GB of 4.0 GB"
        var s = ImportSnapshot()
        s.waiting = .sending
        s.rows = [
            ImportRow(
                id: "big-1",
                name: "takeout-2026.zip",
                kind: .sending,
                retryable: false,
                savedAtJournal: false,
                byteSize: fourGiB,
                progress: ImportResumableProgress(bytesSent: onePointTwoGiB, bytesTotal: fourGiB, phase: .sending)
            ),
        ]
        let activeSingle = deriveImportTile(s)
        #expect(activeSingle.state == .sending)
        #expect(activeSingle.displayedWord == "sending")
        #expect(activeSingle.subline == "1.2 GB of 4.0 GB")
        #expect(activeSingle.accessibilityValue == "sending. 1.2 GB of 4.0 GB.")

        // Active resumable sending with 2 more waiting -> "1.2 GB of 4.0 GB · 2 more waiting"
        s.rows.append(ImportRow(id: "w-1", name: "a.pdf", kind: .waiting, retryable: false, savedAtJournal: false))
        s.rows.append(ImportRow(id: "w-2", name: "b.pdf", kind: .waiting, retryable: false, savedAtJournal: false))
        let activeQueued = deriveImportTile(s)
        #expect(activeQueued.state == .sending)
        #expect(activeQueued.subline == "1.2 GB of 4.0 GB · 2 more waiting")

        // Checking phase at commit -> displayedWord "checking file" while state stays .sending
        s.rows = [
            ImportRow(
                id: "big-1",
                name: "takeout-2026.zip",
                kind: .sending,
                retryable: false,
                savedAtJournal: false,
                byteSize: fourGiB,
                progress: ImportResumableProgress(bytesSent: fourGiB, bytesTotal: fourGiB, phase: .checking)
            ),
        ]
        let checking = deriveImportTile(s)
        #expect(checking.state == .sending)
        #expect(checking.displayedWord == "checking file")
        #expect(checking.subline == "takeout-2026.zip")
        #expect(checking.accessibilityValue == "checking file. takeout-2026.zip.")

        // Paused mid-transfer (non-fault) outranks plain waiting, loses to sending / review / fault
        s.waiting = .waiting
        s.offline = true
        s.rows = [
            ImportRow(
                id: "big-1",
                name: "takeout-2026.zip",
                kind: .paused,
                retryable: false,
                savedAtJournal: false,
                byteSize: fourGiB,
                progress: ImportResumableProgress(bytesSent: onePointTwoGiB, bytesTotal: fourGiB, phase: .paused)
            ),
            ImportRow(id: "w-1", name: "a.pdf", kind: .waiting, retryable: false, savedAtJournal: false),
        ]
        let paused = deriveImportTile(s)
        #expect(paused.state == .paused)
        #expect(paused.state.axToken == "paused")
        #expect(paused.displayedWord == "paused")
        #expect(paused.subline == "1.2 GB of 4.0 GB · 1 more waiting")

        // Actionable fault detail mapping for 507 / 422 / 404
        let spaceRow = ImportRow(
            id: "e1", name: "big.zip", kind: .refused("server msg"), retryable: true,
            savedAtJournal: false, reasonCode: "insufficient_journal_space", byteSize: fourGiB
        )
        #expect(ImportCopy.faultDetail(for: spaceRow, serverSentence: "server msg")
            == "not enough space where your journal lives for this 4.0 GB file. free up space there or cancel unfinished imports, then try again.")
        let corruptRow = ImportRow(
            id: "e2", name: "big.zip", kind: .refused("server msg"), retryable: true,
            savedAtJournal: false, reasonCode: "whole_file_checksum_mismatch", byteSize: fourGiB
        )
        #expect(ImportCopy.faultDetail(for: corruptRow, serverSentence: "server msg")
            == "the file didn't arrive intact. try sending it again.")
        let goneRow = ImportRow(
            id: "e3", name: "big.zip", kind: .refused("server msg"), retryable: true,
            savedAtJournal: false, reasonCode: "upload_not_found", byteSize: fourGiB
        )
        #expect(ImportCopy.faultDetail(for: goneRow, serverSentence: "server msg")
            == "this unfinished import is no longer waiting in your journal. try again to start over.")

        // Paused detail routes formatted progress through the single paused-detail catalog entry
        let progress = ImportResumableProgress(bytesSent: onePointTwoGiB, bytesTotal: fourGiB, phase: .paused)
        #expect(ImportCopy.pausedDetail(progress: progress)
            == MacStrings.macos_desktopimportpage_pauseddetail("1.2 GB", "4.0 GB"))
    }

    @Test func deckKeyboardNavigationIncludesImportTile() {
        let order: [DeckTileFocus] = DeckSource.allCases.map { .source($0) } + [.importTile]
        #expect(moveDeckTileFocus(from: .source(.screenshots), direction: .right, order: order, columns: 3) == .importTile)
        #expect(moveDeckTileFocus(from: .importTile, direction: .left, order: order, columns: 3) == .source(.screenshots))
        #expect(moveDeckTileFocus(from: .importTile, direction: .up, order: order, columns: 3) == .source(.browsers))
        #expect(moveDeckTileFocus(from: .source(.browsers), direction: .down, order: order, columns: 3) == .importTile)
        #expect(moveDeckTileFocus(from: .importTile, direction: .up, order: order, columns: 2) == .source(.obsidian))
        #expect(moveDeckTileFocus(from: .importTile, direction: .right, order: order, columns: 3) == .importTile)
    }

    @Test func readyToReviewPillAndMenuRollupHonorFaultBoundary() {
        let reviewPill = deriveJournalPill(JournalPillInputs(readyToReview: 2))
        #expect(reviewPill == .readyToReview(2))
        #expect(reviewPill.text == "2 ready to review")
        #expect(reviewPill.waiting == 0)
        #expect(!reviewPill.isCaughtUp)
        #expect(menuStatusLine(reviewPill) == "connected · 2 ready to review")

        // Real faults & earlier states beat readyToReview
        #expect(deriveJournalPill(JournalPillInputs(held: .importsNeedYou, readyToReview: 2)) == .connectedHeld(.importsNeedYou))
        #expect(deriveJournalPill(JournalPillInputs(pending: 1, readyToReview: 2)) == .waiting(1))
        #expect(deriveJournalPill(JournalPillInputs(connection: .offline, readyToReview: 2)) == .offline(waiting: 0))
        #expect(deriveJournalPill(JournalPillInputs(markHeld: true, readyToReview: 2)) == .confirmMark(waiting: 0))

        // Real import fault rolls up to deckHasFault and menu attention row; readyToReview does NOT
        let cleanTiles = deriveDeck(DeckInputs())
        #expect(!deckHasFault(cleanTiles, importHasFault: false))
        #expect(deckHasFault(cleanTiles, importHasFault: true))

        var reviewOnly = ImportSnapshot()
        reviewOnly.rows = [ImportRow(id: "r1", name: "a.zip", kind: .readyToReview, retryable: false, savedAtJournal: true, importID: "20261122_140000")]
        #expect(!reviewOnly.hasFault)
        #expect(reviewOnly.readyToReviewCount == 1)

        let faultMenu = shellMenuRows(
            tiles: cleanTiles, pill: .connectedHeld(.importsNeedYou), pausedLine: nil,
            canPause: true, canResume: false, hasJournal: true, canOpenJournal: true,
            update: .upToDate, importHasFault: true
        )
        #expect(faultMenu.first == .importAttention)

        let reviewMenu = shellMenuRows(
            tiles: cleanTiles, pill: reviewPill, pausedLine: nil,
            canPause: true, canResume: false, hasJournal: true, canOpenJournal: true,
            update: .upToDate, importHasFault: false
        )
        #expect(!reviewMenu.contains(.importAttention))
        #expect(reviewMenu.first == .status("connected · 2 ready to review"))
    }

    @Test func onDeviceRowsSortActionableFirstAndExcludeReviewRows() {
        var s = ImportSnapshot()
        s.rows = [
            ImportRow(id: "w1", name: "waiting.txt", kind: .waiting, retryable: false, savedAtJournal: false),
            ImportRow(id: "r1", name: "review.zip", kind: .readyToReview, retryable: false, savedAtJournal: true, importID: "20261122_140000"),
            ImportRow(id: "s1", name: "sending.pdf", kind: .sending, retryable: false, savedAtJournal: false),
            ImportRow(id: "f1", name: "refused.bin", kind: .refused("bad"), retryable: false, savedAtJournal: false),
            ImportRow(id: "m1", name: "missing.jpg", kind: .missingCopy, retryable: false, savedAtJournal: false),
        ]
        #expect(s.reviewRows.map(\.id) == ["r1"])
        #expect(s.onDeviceRows.map(\.id) == ["f1", "m1", "s1", "w1"])
    }

    @Test func importTotalFactsFormatsItemsAndHidesWhenUnreadable() throws {
        let now = try #require(SourceTotals.parseInstant("2026-11-22T15:00:00Z"))
        #expect(importTotalFacts(nil, now: now, calendar: utc) == nil)

        let empty = try #require(importTotalFacts(view(), now: now, calendar: utc))
        #expect(empty.soFar == "nothing yet")
        #expect(empty.lastTakenIn == nil)

        var oneView = view()
        oneView.importsTotal = 1
        oneView.importsLast = "2026-11-22T14:58:00Z"
        oneView.importsStarted = "2026-11-22"
        let one = try #require(importTotalFacts(oneView, now: now, calendar: utc))
        #expect(one.totalOnly == "1 item")
        #expect(one.lastTakenIn == "2 min ago")

        var manyView = view()
        manyView.importsTotal = 1_234
        manyView.importsLast = "2026-11-22T12:00:00Z"
        manyView.importsStarted = "2026-03-03"
        let many = try #require(importTotalFacts(manyView, now: now, calendar: utc))
        #expect(many.totalOnly == "1,234 items")
        #expect(many.soFar.contains("1,234 items"))
        #expect(many.lastTakenIn == "3 hours ago")
    }

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    @Test @MainActor func browserDeclarationsOmitColdStartAndQuiescenceAndEmitConfiguredFaultsIncludingWhilePaused() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func declarations(
            snapshot: BrowserHostSnapshotValue,
            safariExtensionNeedsAttention: Bool = false,
            ownerPaused: Bool = false
        ) -> [SourceDeclaration] {
            var inputs = DeckInputs()
            inputs.microphoneOn = false
            inputs.screenOn = false
            inputs.terminalOn = false
            inputs.browsersOn = true
            inputs.ownerPaused = ownerPaused
            inputs.browserState = AppState.deriveDeckBrowserState(
                snapshot: snapshot,
                safariExtensionNeedsAttention: safariExtensionNeedsAttention,
                hasJournal: true,
                ownerPaused: ownerPaused,
                now: now
            )
            let configured = AppState.browserConfiguredForDeclaration(
                snapshot: snapshot,
                safariExtensionNeedsAttention: safariExtensionNeedsAttention,
                now: now
            )
            return inputs.declarations(vaultConfirmed: false, browserConfigured: configured, permissionsChecked: true)
        }

        // Cold-start (capture == "unavailable", listener == .unavailable, connectedCount == 0) omits "browsers".
        let coldStart = BrowserHostSnapshotValue(capture: "unavailable", listener: .unavailable)
        #expect(!AppState.browserConfiguredForDeclaration(snapshot: coldStart, safariExtensionNeedsAttention: false, now: now))
        #expect(declarations(snapshot: coldStart).isEmpty)

        // Normal Quit / Sparkle quiescence and shutdown with zero connected browsers omit "browsers".
        let quiescent = BrowserHostSnapshotValue(capture: "permitted", listener: .available, quiescence: true)
        let shuttingDown = BrowserHostSnapshotValue(capture: "permitted", listener: .available, shutdown: true)
        #expect(!AppState.browserConfiguredForDeclaration(snapshot: quiescent, safariExtensionNeedsAttention: false, now: now))
        #expect(!AppState.browserConfiguredForDeclaration(snapshot: shuttingDown, safariExtensionNeedsAttention: false, now: now))
        #expect(declarations(snapshot: quiescent).isEmpty)
        #expect(declarations(snapshot: shuttingDown).isEmpty)

        // Safari extension fault emits {"source": "browsers", "state": "needs_attention"} both unpaused and paused.
        for paused in [false, true] {
            #expect(declarations(snapshot: coldStart, safariExtensionNeedsAttention: true, ownerPaused: paused)
                == [SourceDeclaration(source: "browsers", state: "needs_attention")])
        }

        // Native-messaging registration .refused emits {"source": "browsers", "state": "needs_attention"} both unpaused and paused.
        let refused = BrowserHostSnapshotValue(
            capture: "permitted",
            registration: [.chrome: BrowserHostRegistrationSummary(state: .refused, reasonCode: "permission_denied")],
            listener: .available
        )
        for paused in [false, true] {
            #expect(declarations(snapshot: refused, ownerPaused: paused)
                == [SourceDeclaration(source: "browsers", state: "needs_attention")])
        }
    }
#endif
}
