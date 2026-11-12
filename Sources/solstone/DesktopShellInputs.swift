// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

extension AppState {
    /// Whether this Mac has a journal on record, the same test the status classifier uses.
    var deckHasJournal: Bool {
        tunnelLifecycleOwner.pairingIdentityRead != .absent || config.isUploadConfigured
    }

    /// Everything the deck's tiles are derived from, read off the running app.
    var deckInputs: DeckInputs {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        if let snapshotDeckInputs { return snapshotDeckInputs }
#endif
        var i = DeckInputs()
        i.paired = deckHasJournal
        i.ownerPaused = pauseManager.isPaused

        i.microphoneOn = config.isMicrophoneCaptureEnabled
        if !initialPermissionCheckComplete {
            i.microphoneAccess = .unknown
        } else {
            switch microphoneAuthorizationCause {
            case .authorized: i.microphoneAccess = .granted
            case .notDetermined: i.microphoneAccess = .notAsked
            case .denied: i.microphoneAccess = .denied
            case .restricted: i.microphoneAccess = .restricted
            case .unknown: i.microphoneAccess = .unknown
            }
        }
        i.microphoneLive = Self.deckLive(permissionSourceLiveState(for: .microphone))

        i.screenOn = config.isScreenCaptureEnabled
        if !initialPermissionCheckComplete || screenRecordingGranted {
            i.screenAccess = .granted
        } else if capture.screenRecordingNeedsRestart {
            i.screenAccess = .needsRestart
        } else if capture.screenRecordingHasPrompted() {
            i.screenAccess = .denied
        } else {
            i.screenAccess = .notAsked
        }
        i.screenLive = Self.deckLive(permissionSourceLiveState(for: .screen))
        i.screenFailure = capture.screenFailure
        i.activityEnabled = config.isActivityEnabled
        if let activity = activitySource {
            i.activityGoingIn = activity.enabled && !activity.paused && !activity.failed
            i.activityFailed = activity.enabled && activity.failed
        } else {
            i.activityGoingIn = false
            i.activityFailed = false
        }
        i.privateWindowsNeedAttention = privateWindowAccessibilityEnabled && privateWindowAccessibilityMonitor.needsAttention
        i.privateWindowsLine = UICopy.SETTINGS_ATTENTION_PRIVATE_WINDOWS
        i.captureError = errorMessage

        i.terminalOn = config.isTerminalEnabled
        if let terminalSource {
            switch terminalSource.state {
            case .off: i.terminalState = .off
            case .paused: i.terminalState = .paused
            case .tmuxNotFound: i.terminalState = .tmuxNotFound
            case .oldAppInstalled: i.terminalState = .oldAppInstalled
            case .running: i.terminalState = .running
            case .restarting: i.terminalState = .restarting
            }
            if let refusal = terminalMoveRefusal {
                i.terminalProblem = refusal
            } else if terminalSource.unsendableCount > 0 {
                i.terminalProblem = UICopy.Terminal.unsendable(terminalSource.unsendableCount)
            }
        } else {
            i.terminalState = .unknown
        }

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        i.browsersOn = config.isBrowserIntakeEnabled
        i.browserState = deckBrowserState
#else
        i.browsersOn = false
#endif

        if let obsidianSource {
            switch obsidianSource.isOn ? obsidianSource.phase : .off {
            case .off: i.obsidianState = .off
            case .on: i.obsidianState = .on
            case .paused: i.obsidianState = .paused
            case .waitingForJournalUpdate: i.obsidianState = .waitingForJournalUpdate
            case .needsAttention: i.obsidianState = .needsAttention
            }
            i.obsidianVaultName = obsidianSource.snapshot.state.vaultName
            i.obsidianAttentionLine = UICopy.Obsidian.attentionLine(
                vaultUnreadable: obsidianSource.snapshot.vaultUnreadable,
                partUnreadable: obsidianSource.snapshot.partUnreadable
            )
        } else {
            i.obsidianState = .unknown
        }
        if let screenshotSource {
            i.screenshot = screenshotSource.snapshot
        }
        return i
    }

    static func deckLive(_ state: PermissionSourceLiveState) -> DeckMediaLive {
        switch state {
        case .on: return .on
        case .paused(.owner): return .ownerPaused
        case .paused(.protectedVideo): return .protectedVideo
        case .off, .notRunning: return .notRunning
        }
    }

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    /// Pausing turns only a running browser source to `paused`; one waiting for a journal stays
    /// `ready to set up` through the pause.
    var deckBrowserState: DeckBrowserState {
        deckBrowserStatePausing(deckBrowserStateBeforePause, ownerPaused: pauseManager.isPaused)
    }

    private var deckBrowserStateBeforePause: DeckBrowserState {
        let snapshot = browserHostSnapshot.value
        let now = Date()
        if safariExtensionNeedsAttention { return .fault(UICopy.SOURCES_BROWSER_SAFARI_UNAVAILABLE) }
        if snapshot.registration.values.contains(where: { $0.state == .refused }) {
            return .fault(UICopy.SOURCES_BROWSER_REGISTRATION_BROKEN)
        }
        // Without a journal, browser pages wait for one: setup, not a fault.
        if !deckHasJournal { return .notPaired }
        let verdict = browserOwnerVerdict(
            mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: snapshot, now: now
        )
        switch verdict.lead {
        case .ready, .waiting, .mediaUnchanged:
            let connected = browserBrandRows(snapshot, now: now).filter { $0.connectedCount > 0 }.map(\.brand.displayName)
            return .running(connected: connected)
        case .paused: return .paused
        case .notPaired: return .notPaired
        case .unknown, .draining, .intakeOff: return .checking
        case .unavailable, .shutdown, .sessionClosed: return .fault(UICopy.SOURCES_BROWSER_CANNOT_START)
        case .custodyFull: return .fault(UICopy.SOURCES_BROWSER_FULL)
        case .hold(let reason):
            return .fault(reason == "unaccepted_lost" ? UICopy.SOURCES_BROWSER_LOST_AND_HELD : UICopy.SOURCES_BROWSER_HELD)
        }
    }
#endif

    var deckTiles: [DeckTile] { deriveDeck(deckInputs) }

    /// What each source has taken in on this install, or nil when the record can't be read.
    var sourceTotalsView: SourceTotals.View? {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        if let snapshotSourceTotals { return snapshotSourceTotals }
#endif
        return SourceTotalsInstall.currentStore()?.view()
    }

    var journalPillInputs: JournalPillInputs {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        if let snapshotJournalPillInputs { return snapshotJournalPillInputs }
#endif
        var i = JournalPillInputs()
        i.bundledService = config.serviceMode == .bundled
        i.hasJournal = deckHasJournal
        i.markHeld = needsJournalMarkConfirmation
        i.syncPaused = config.syncPaused
        switch tunnelLifecycleOwner.connectionVerdict.failureCause {
        case .revoked, .mismatch, .notEntitled: i.pairingRefused = true
        default: i.pairingRefused = false
        }
        i.connection = deckConnection(classifyJournalConnection(
            isPairedIngestReady: isPairedIngestReady,
            presentedConnection: tunnelLifecycleOwner.presentedConnection,
            uploadStatus: uploadCoordinator.status,
            lastHealthReason: uploadCoordinator.lastHealthReason
        ))
        i.upload = deckUploadPhase(uploadCoordinator.status)
        i.pending = uploadCoordinator.pendingCount
        if deckHasJournal, !uploadCoordinator.unwrittenSegments.isEmpty {
            i.held = .segmentsNotWritten
        }
        return i
    }

    var journalPill: JournalPill { deriveJournalPill(journalPillInputs) }

    /// The one switch action every surface shares. Obsidian's on needs a folder, so its caller
    /// opens its page instead; this only turns it off.
    func setDeckSource(_ source: DeckSource, on: Bool) {
        switch source {
        case .audio, .screen:
            var next = config
            if source == .audio { next.isMicrophoneCaptureEnabled = on } else { next.isScreenCaptureEnabled = on }
            updateConfig(next)
            Task { await applySelectedSourcesToRunningSession() }
        case .terminal:
            setTerminalEnabled(on)
        case .browsers:
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            setBrowserIntakeEnabled(on)
#endif
        case .obsidian:
            guard !on, let obsidianSource else { return }
            Task { await obsidianSource.turnOff() }
        case .screenshots:
            guard !on, let screenshotSource else { return }
            Task { await screenshotSource.turnOff() }
        }
    }

    /// Whether `pause ▾` or `resume` shows: the 2.0.64 menu's own rule, unchanged.
    var deckPauseControls: (pause: Bool, resume: Bool) {
        let activity = activitySource
        let activityPausable = activity.map { $0.enabled && !$0.paused && !$0.failed } ?? false
            && !config.activityContinuesThroughPause
        let activityResumable = (activity?.enabled ?? false) && pauseManager.isPaused
            && !config.activityContinuesThroughPause
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let controls = menuPauseControls(
            mediaRecording: isRecording,
            mediaPaused: isPaused,
            mediaUserPaused: capture.isUserPaused,
            pauseManagerPaused: pauseManager.isPaused,
            browserCapturePermitted: browserPauseEnabled
        )
        let pause = activityPausable || controls.pause
        let resume = activityResumable || controls.resume
#else
        let pause = activityPausable || (isRecording && !isPaused)
        let resume = activityResumable || capture.isUserPaused || ownerPauseHeldIdle
#endif
        let shots = screenshotSource?.snapshot
        return withScreenshotsPause(
            (pause, resume),
            screenshotsRunning: shots?.state == .on,
            screenshotsPaused: shots?.state == .paused,
            computerPaused: pauseManager.isPaused
        )
    }
}

/// The computer's pause covers every running source (desktop-shell § 2.9), so a running
/// screenshots source offers `pause`, and a paused one offers `resume`, even when nothing
/// else is recording.
func withScreenshotsPause(
    _ controls: (pause: Bool, resume: Bool),
    screenshotsRunning: Bool,
    screenshotsPaused: Bool,
    computerPaused: Bool
) -> (pause: Bool, resume: Bool) {
    let pause = controls.pause || (screenshotsRunning && !computerPaused)
    let resume = controls.resume || (screenshotsPaused && computerPaused)
    return (pause, !pause && resume)
}
