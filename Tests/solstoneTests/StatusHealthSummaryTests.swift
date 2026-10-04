import Foundation
import Testing
import SolstoneCore
@testable import solstone

private let statusSummaryNow = Date(timeIntervalSince1970: 1_000_000)
private let statusSummaryRecentDelivery = statusSummaryNow.addingTimeInterval(-120)
private let statusSummaryServerURL = "https://x.example:5015"

@Suite("StatusHealthSummary")
struct StatusHealthSummaryTests {
    @Test func blockedUploadNamesTheCauseAndDoesNotOfferCaptureRestart() {
        let status = UploadCoordinator.Status.blocked("upload exceeds journal limits")
        let summary = makeSummary(uploadStatus: status, pendingCount: 1)
        #expect(summary.severity == .attention)
        #expect(summary.title == "upload exceeds journal limits")
        #expect(summary.axValue == "external_blocked")
        #expect(classifyJournalConnection(isPairedIngestReady: true, uploadStatus: status, journalConnectionAXToken: nil) == .error)
        #expect(observationRecoveryPresentation(observationRowState: .error, errorMessage: nil, tryAgainInFlight: false, uploadStatus: status) == nil)
        #expect(observationRecoveryPresentation(observationRowState: .error, errorMessage: "capture stopped", tryAgainInFlight: false, uploadStatus: status) != nil)
    }
    @Test func currentConnectionOverridesStaleDeliverySuccessInBothSurfaces() {
        for connecting in [true, false] {
            let token = connecting ? PairingConnectionAXState.connecting.axToken : nil
            let summary = StatusHealthSummary.make(
                serviceMode: .external, isRecording: true, isPaused: false, held: false,
                hasPersistedPairing: true,
                uploadStatus: .synced, pendingCount: 0,
                lastDeliveryOutcome: .delivered(statusSummaryRecentDelivery),
                journalSlot: "x.example", now: statusSummaryNow,
                isPairedIngestReady: false, journalConnectionAXToken: token
            )
            #expect(summary.severity == (connecting ? .warn : .attention))
            #expect(summary.axValue == (connecting ? "external_awaiting_tunnel" : "external_offline"))
            #expect(classifyJournalConnection(isPairedIngestReady: false, uploadStatus: .synced, journalConnectionAXToken: token) == (connecting ? .connectionWaiting : .offline))
        }
        #expect(classifyJournalConnection(isPairedIngestReady: true, uploadStatus: .retrying(segment: "s", attempts: 1), journalConnectionAXToken: nil) == .observing)
        let retry = makeSummary(uploadStatus: .retrying(segment: "s", attempts: 1))
        #expect(retry.severity == .warn)
        #expect(retry.axValue == "external_retrying")
        let delivered = makeSummary(uploadStatus: .synced)
        #expect(delivered.severity == .good)
    }
    @Test func absentPairingOutranksRememberedDeliveryAndConnectionWaits() {
        for mode in [ServiceMode.external, .bundled] {
            for status in [UploadCoordinator.Status.synced, .awaitingTunnel, .notSynced] {
                let summary = makeSummary(
                    serviceMode: mode,
                    hasPersistedPairing: false,
                    uploadStatus: status,
                    setupVerdict: .needsAttention(count: 1)
                )
                #expect(summary.axValue == "external_not_linked")
                #expect(summary.severity == .attention)
                let action = try! #require(summary.action)
                #expect(healthActionEffect(action).tab == .service)
                #expect(!action.reasksJournalMark)
            }
        }
        let pausedBacklog = makeSummary(isRecording: false, isPaused: true, hasPersistedPairing: false, pendingCount: 2)
        #expect(pausedBacklog.axValue == "external_not_linked")
        #expect(pausedBacklog.severity == .attention)
        let stoppedEmpty = makeSummary(isRecording: false, hasPersistedPairing: false)
        #expect(stoppedEmpty.severity == .calm)
        let resumed = makeSummary(hasPersistedPairing: true)
        #expect(resumed.axValue == "external_synced")
        #expect(resumed.severity == .good)
    }
    @Test func stoppedCaptureCannotHideAnAbsentJournalLink() {
        for sources in [CaptureSources.all, []] {
            let summary = makeSummary(
                isRecording: false,
                hasPersistedPairing: false,
                pendingCount: 2,
                selectedSources: sources,
                permittedSources: [],
                errorMessage: "source unavailable"
            )
            #expect(summary.axValue == "external_not_linked")
            #expect(summary.severity == .attention)
            #expect(summary.action?.settingsTab == "service")
        }
    }
    @Test func bundledModeAlwaysReportsMigrationNeeded() {
        let summary = makeSummary(serviceMode: .bundled, isRecording: false, isPaused: true, uploadStatus: .synced)

        #expect(summary.severity == .attention)
        #expect(summary.title == "your journal needs a new link")
        #expect(summary.subtitle == "open your journal panel to connect this mac again")
        #expect(summary.axValue == MenubarStatusRowState.journalMigrationNeeded.axToken)
    }

    @Test func externalOfflineRowReportsBacklogWithoutBytes() {
        let waiting = makeSummary(uploadStatus: .offline("offline"), pendingCount: 3)

        #expect(waiting.severity == .attention)
        #expect(waiting.axValue == "external_offline")
        #expect(waiting.subtitle?.contains("3 segments waiting here") == true)
        #expect(waiting.subtitle?.contains("MB") == false)
        #expect(waiting.subtitle?.contains("bytes") == false)

        let empty = makeSummary(uploadStatus: .offline("offline"), pendingCount: 0)

        #expect(empty.severity == .attention)
        #expect(empty.axValue == "external_offline")
        #expect(empty.subtitle == "nothing is lost · sync resumes when it's back")
        #expect(empty.subtitle?.contains("MB") == false)
        #expect(empty.subtitle?.contains("bytes") == false)
    }

    @Test func externalAwaitingTunnelReportsConnectionWait() {
        let waiting = makeSummary(uploadStatus: .awaitingTunnel, pendingCount: 2)

        #expect(waiting.severity == .warn)
        #expect(waiting.axValue == "external_awaiting_tunnel")
        #expect(waiting.title == "connecting to your journal…")
        #expect(waiting.subtitle == "2 segments waiting here")
    }

    // An owner who turned both switches off chose this, so it is calm, it says what it is,
    // and it carries the one action that undoes it. It must NOT read as a fault.
    @Test func bothSourcesOffIsCalmAndNamesItsCauseAndItsWayBack() {
        let off = makeSummary(isRecording: false, selectedSources: [])
        #expect(off.severity == .calm)
        #expect(off.axValue == "sources_off")
        #expect(off.title == UICopy.SOURCES_NONE)
        #expect(off.subtitle == UICopy.SOURCES_NONE_REASON)
        #expect(off.action?.settingsTab == "sources")
    }

    // Wanting a source macOS has not granted is a fault, and it routes to the grant, not
    // to the switches the owner already set correctly.
    @Test func selectedButUngrantedSourcesNeedAttentionAndRouteToPermissions() {
        let blocked = makeSummary(isRecording: false, selectedSources: .all, permittedSources: [])
        #expect(blocked.severity == .attention)
        #expect(blocked.axValue == "sources_unavailable")
        #expect(blocked.title == "what you turned on isn't granted yet")
        #expect(blocked.action?.settingsTab == "permissions")
    }

    // Selected, permitted, and not running yet is the brief window before auto-start.
    @Test func notRunningWithAUsableSourceReadsAsStartingUp() {
        let starting = makeSummary(isRecording: false)
        #expect(starting.severity == .calm)
        #expect(starting.axValue == "off")
        #expect(starting.title == "starting…")
        #expect(starting.subtitle == "nothing is reaching your journal yet")
    }

    @Test func pausedRowUsesSyncSpecificSubtitle() {
        let synced = makeSummary(isPaused: true, uploadStatus: .synced)
        #expect(synced.severity == .warn)
        #expect(synced.axValue == "paused")
        #expect(synced.subtitle == "synced to x.example")

        let connecting = makeSummary(isPaused: true, uploadStatus: .notSynced)
        #expect(connecting.severity == .warn)
        #expect(connecting.axValue == "paused")
        #expect(connecting.subtitle == "paused · x.example")
    }

    @Test func externalInProgressRowsMapToWarningStates() {
        let retrying = makeSummary(uploadStatus: .retrying(segment: "s1", attempts: 2), pendingCount: 2)
        #expect(retrying.severity == .warn)
        #expect(retrying.axValue == "external_retrying")
        #expect(retrying.subtitle?.contains("2 segments waiting") == true)

        let syncing = makeSummary(uploadStatus: .syncing(checked: 2, total: 5))
        #expect(syncing.severity == .warn)
        #expect(syncing.axValue == "external_syncing")
        #expect(syncing.title == "catching up · 2 of 5 segments")
        #expect(syncing.subtitle == "syncing to your journal")

        let uploading = makeSummary(uploadStatus: .uploading(segment: "s2"), pendingCount: 4)
        #expect(uploading.severity == .warn)
        #expect(uploading.axValue == "external_uploading")
        #expect(uploading.subtitle?.contains("4 more waiting") == true)

        let connecting = makeSummary(uploadStatus: .notSynced)
        #expect(connecting.severity == .warn)
        #expect(connecting.axValue == "external_connecting")
        #expect(connecting.subtitle == "reaching your journal")
    }

    @Test func externalGreenRequiresBothSyncedUploadStatusAndConfirmedDelivery() {
        let synced = makeSummary(uploadStatus: .synced)
        #expect(synced.severity == .good)
        #expect(synced.axValue == "external_synced")

        let contactOnly = makeSummary(uploadStatus: .synced, lastDeliveryOutcome: .noDeliveryYet)
        #expect(contactOnly.severity == .calm)
        #expect(contactOnly.axValue == "external_no_delivery_yet")
        #expect(contactOnly.title == UICopy.SETTINGS_OBSERVATION_OBSERVING)
        #expect(contactOnly.subtitle == "nothing added yet · nothing waiting")

        let notSynced = makeSummary(uploadStatus: .notSynced)
        #expect(notSynced.severity == .warn)
        #expect(notSynced.axValue == "external_connecting")

        let uploading = makeSummary(uploadStatus: .uploading(segment: "s1"))
        #expect(uploading.severity == .warn)
        #expect(uploading.axValue == "external_uploading")

        let retrying = makeSummary(uploadStatus: .retrying(segment: "s1", attempts: 2))
        #expect(retrying.severity == .warn)
        #expect(retrying.axValue == "external_retrying")
    }

    @Test func externalHealthySubtitleUsesDeliveryNotContact() {
        let nothingWaiting = makeSummary(
            uploadStatus: .synced,
            pendingCount: 0,
            lastDeliveryOutcome: .delivered(statusSummaryRecentDelivery)
        )
        #expect(nothingWaiting.subtitle == "last added to your journal 2m ago · nothing waiting")

        let waiting = makeSummary(
            uploadStatus: .synced,
            pendingCount: 5,
            lastDeliveryOutcome: .delivered(statusSummaryRecentDelivery)
        )
        #expect(waiting.subtitle == "last added to your journal 2m ago · 5 waiting")

        let unavailable = makeSummary(uploadStatus: .synced, lastDeliveryOutcome: .unavailable)
        #expect(unavailable.severity == .warn)
        #expect(unavailable.subtitle == "couldn't check")
    }

    @Test func setupReadyPreservesOperationalSummary() {
        let summary = makeSummary(uploadStatus: .synced, setupVerdict: .ready)

        #expect(summary.severity == .good)
        #expect(summary.title == "all good · on, synced to x.example")
        #expect(summary.axValue == "external_synced")
    }

    @Test func setupNeedsAttentionOverridesHealthyOperationalSummary() {
        let summary = makeSummary(uploadStatus: .synced, setupVerdict: .needsAttention(count: 2))

        #expect(summary.severity == .attention)
        #expect(summary.title == "2 things need attention")
        #expect(summary.subtitle == "all good · on, synced to x.example")
        #expect(summary.axValue == SetupGroupVerdictAXState.needsAttention.axToken)
    }

    @Test func setupUnavailableOverridesHealthyOperationalSummary() {
        let summary = makeSummary(uploadStatus: .synced, setupVerdict: .someUnavailable)

        #expect(summary.severity == .attention)
        #expect(summary.title == "some setup checks are unavailable")
        #expect(summary.axValue == SetupGroupVerdictAXState.someUnavailable.axToken)
    }

    @Test func captureFlagsLoseToRedRowsAndPrecedeExternalProgressRows() {
        let uploadingOff = makeSummary(isRecording: false, uploadStatus: .uploading(segment: "s1"))
        #expect(uploadingOff.axValue == "off")

        let syncedPaused = makeSummary(isPaused: true, uploadStatus: .synced)
        #expect(syncedPaused.axValue == "paused")

        let offlinePaused = makeSummary(isPaused: true, uploadStatus: .offline("offline"))
        #expect(offlinePaused.axValue == "external_offline")
    }

    @Test func coarseRelativeTimeBuckets() {
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(-30), now: statusSummaryNow) == "just now")
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(30), now: statusSummaryNow) == "just now")
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(-120), now: statusSummaryNow) == "2m ago")
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(-7_200), now: statusSummaryNow) == "2h ago")
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(-172_800), now: statusSummaryNow) == "2d ago")
    }

    // MARK: - a failed capture is not a starting capture

    @Test func captureErrorLeadsTheCardInsteadOfStarting() {
        let summary = makeSummary(
            isRecording: false,
            errorMessage: UICopy.ERROR_START_OBSERVING
        )
        #expect(summary.severity == .attention)
        #expect(summary.title == UICopy.STATUS_CAPTURE_ERROR_TITLE)
        #expect(summary.subtitle == UICopy.ERROR_START_OBSERVING)
        #expect(summary.axValue == "capture_error")
        #expect(summary.title != UICopy.MENUBAR_STARTING)
    }

    // The inverted direction: without an error the calm starting state must survive, so an
    // implementation that simply reddens every not-recording card fails this.
    @Test func noErrorStillReadsAsStarting() {
        let summary = makeSummary(isRecording: false, errorMessage: nil)
        #expect(summary.title == UICopy.MENUBAR_STARTING)
        #expect(summary.severity == .calm)
    }

    @Test func emptyErrorIsNotAnError() {
        let summary = makeSummary(isRecording: false, errorMessage: "")
        #expect(summary.title == UICopy.MENUBAR_STARTING)
    }

    // Precedence: a configuration fault the owner chose outranks a run fault, matching the
    // menubar classifier, which tests permissions before errorMessage.
    @Test func bothSourcesOffOutranksACaptureError() {
        let summary = makeSummary(
            isRecording: false,
            selectedSources: [],
            errorMessage: UICopy.ERROR_START_OBSERVING
        )
        #expect(summary.title == UICopy.SOURCES_NONE)
    }

    // A running or paused session is never relabelled by a stale error string.
    @Test func aRunningSessionIsNotRelabelledByAnError() {
        let summary = makeSummary(isRecording: true, errorMessage: UICopy.ERROR_START_OBSERVING)
        #expect(summary.title != UICopy.STATUS_CAPTURE_ERROR_TITLE)
    }

    @Test func offlineTitlesForSpecificHealthReasonsMatchOwnerCopy() {
        let reasons: [(ObserverHealthFailureReason, String)] = [
            (.pairingRevoked, "pairing was revoked. pair again to reconnect."),
            (.journalNotServing, "your journal isn't taking this in"),
            (.journalRefused(reasonCode: "foreign_stream_binding"), "your journal refused this sync."),
            (.journalRejectedDay(day: "20260915", reasonCode: "journal_read_failed"), "your journal couldn't read 2026-09-15"),
        ]
        for (reason, expectedCopy) in reasons {
            let copy = classifiedObserverHealthOwnerCopy(reason)
            #expect(copy == expectedCopy)
            let summary = makeSummary(uploadStatus: .offline(copy), lastHealthReason: reason)
            #expect(summary.title == expectedCopy)
            #expect(!summary.title.contains("can't reach"))
        }
    }

    @Test func heldRecordingUsesHeldCopyAndActionAcrossUploadStatuses() {
        let statuses: [(UploadCoordinator.Status, Int)] = [
            (.notSynced, 0),
            (.syncing(checked: 1, total: 4), 0),
            (.synced, 3),
            (.uploading(segment: "s1"), 0),
            (.retrying(segment: "s1", attempts: 2), 0),
            (.offline("stale"), 0),
            (.awaitingTunnel, 3)
        ]

        for (status, pending) in statuses {
            let summary = makeSummary(isRecording: true, isPaused: false, held: true, uploadStatus: status, pendingCount: pending)
            #expect(summary.severity == .calm)
            #expect(summary.title == UICopy.JOURNAL_MARK_HELD)
            #expect(summary.subtitle == UICopy.JOURNAL_MARK_HELD_CAPTION)
            #expect(summary.axValue == "external_awaiting_mark_confirmation")
            #expect(summary.action != nil)
            if let action = summary.action {
                #expect(action.label == UICopy.JOURNAL_MARK_CONFIRM_ACTION)
                #expect(SettingsView.Tab(rawValue: action.settingsTab) == .service)
                #expect(action.reasksJournalMark == true)
            }
        }
    }

    @Test func heldPausedUsesPausedCardMatchingNotSyncedPaused() {
        let statuses: [UploadCoordinator.Status] = [.notSynced, .awaitingTunnel, .synced]
        let baseline = makeSummary(isRecording: true, isPaused: true, held: false, uploadStatus: .notSynced)

        for status in statuses {
            let summary = makeSummary(isRecording: true, isPaused: true, held: true, uploadStatus: status)
            #expect(summary.axValue == "paused")
            #expect(summary == baseline)
        }
    }

    @Test func unheldPausedSyncedDiffersFromNotSyncedAndOfflineIsAttention() {
        let notSyncedPaused = makeSummary(isRecording: true, isPaused: true, held: false, uploadStatus: .notSynced)
        let syncedPaused = makeSummary(isRecording: true, isPaused: true, held: false, uploadStatus: .synced)
        #expect(syncedPaused != notSyncedPaused)

        let offlinePaused = makeSummary(isRecording: true, isPaused: true, held: false, uploadStatus: .offline("offline"))
        #expect(offlinePaused.axValue == "external_offline")
    }

    @Test func heldBundledYieldsMigrationCardWithoutAction() {
        let heldBundled = makeSummary(serviceMode: .bundled, isRecording: true, isPaused: false, held: true)
        let unheldBundled = makeSummary(serviceMode: .bundled, isRecording: true, isPaused: false, held: false)

        #expect(heldBundled == unheldBundled)
        #expect(heldBundled.action == nil)
        #expect(heldBundled.axValue == MenubarStatusRowState.journalMigrationNeeded.axToken)
    }

    @Test func heldAttentionSetupWrapsWithHeldActionAndPreservesSetupToken() {
        let verdict = SetupGroupVerdict.needsAttention(count: 2)
        let heldUnwrapped = makeSummary(isRecording: true, isPaused: false, held: true, setupVerdict: nil)
        let summary = makeSummary(isRecording: true, isPaused: false, held: true, setupVerdict: verdict)

        #expect(summary.severity == .attention)
        #expect(summary.title == verdict.text)
        #expect(summary.subtitle == heldUnwrapped.title)
        #expect(summary.action == heldUnwrapped.action)
        #expect(summary.action != nil)
        #expect(summary.axValue == verdict.axState.axToken)

        let readySummary = makeSummary(isRecording: true, isPaused: false, held: true, setupVerdict: .ready)
        #expect(readySummary == heldUnwrapped)
    }

    @Test func heldOffStatesMatchUnheldCards() {
        let notRecordingHeld = makeSummary(isRecording: false, isPaused: false, held: true)
        let notRecordingUnheld = makeSummary(isRecording: false, isPaused: false, held: false)
        #expect(notRecordingHeld == notRecordingUnheld)

        let sourcesOffHeld = makeSummary(isRecording: false, isPaused: false, held: true, selectedSources: [])
        let sourcesOffUnheld = makeSummary(isRecording: false, isPaused: false, held: false, selectedSources: [])
        #expect(sourcesOffHeld == sourcesOffUnheld)

        let sourcesUnavailableHeld = makeSummary(isRecording: false, isPaused: false, held: true, selectedSources: .screen, permittedSources: .microphone)
        let sourcesUnavailableUnheld = makeSummary(isRecording: false, isPaused: false, held: false, selectedSources: .screen, permittedSources: .microphone)
        #expect(sourcesUnavailableHeld == sourcesUnavailableUnheld)

        let captureErrorHeld = makeSummary(isRecording: false, isPaused: false, held: true, errorMessage: "fail")
        let captureErrorUnheld = makeSummary(isRecording: false, isPaused: false, held: false, errorMessage: "fail")
        #expect(captureErrorHeld == captureErrorUnheld)
    }

    @Test func healthActionEffectRoutesHeldActionToServiceAndTriggersReask() {
        let sourcesAction = StatusHealthAction(label: UICopy.SOURCES_OPEN_ACTION, settingsTab: "sources", reasksJournalMark: false)
        let sourcesEffect = healthActionEffect(sourcesAction)
        #expect(sourcesEffect.tab == .sources)
        #expect(sourcesEffect.postsReask == false)

        let permissionsAction = StatusHealthAction(label: UICopy.PERMISSIONS_OPEN_ACTION, settingsTab: "permissions", reasksJournalMark: false)
        let permissionsEffect = healthActionEffect(permissionsAction)
        #expect(permissionsEffect.tab == .permissions)
        #expect(permissionsEffect.postsReask == false)

        let heldCard = makeSummary(isRecording: true, isPaused: false, held: true)
        let heldAction = try! #require(heldCard.action)
        let heldEffect = healthActionEffect(heldAction)
        #expect(heldEffect.tab == .service)
        #expect(heldEffect.postsReask == true)
    }

    private func makeSummary(
        serviceMode: ServiceMode? = .external,
        isRecording: Bool = true,
        isPaused: Bool = false,
        held: Bool = false,
        hasPersistedPairing: Bool = true,
        uploadStatus: UploadCoordinator.Status = .synced,
        pendingCount: Int = 0,
        lastDeliveryOutcome: LastJournalDeliveryOutcome = .delivered(statusSummaryRecentDelivery),
        journalSlot: String = "x.example",
        now: Date = statusSummaryNow,
        selectedSources: CaptureSources = .all,
        permittedSources: CaptureSources = .all,
        errorMessage: String? = nil,
        setupVerdict: SetupGroupVerdict? = nil,
        lastHealthReason: ObserverHealthFailureReason? = nil
    ) -> StatusHealthSummary {
        StatusHealthSummary.make(
            serviceMode: serviceMode,
            isRecording: isRecording,
            isPaused: isPaused,
            held: held,
            hasPersistedPairing: hasPersistedPairing,
            uploadStatus: uploadStatus,
            pendingCount: pendingCount,
            lastDeliveryOutcome: lastDeliveryOutcome,
            journalSlot: journalSlot,
            now: now,
            selectedSources: selectedSources,
            permittedSources: permittedSources,
            errorMessage: errorMessage,
            setupVerdict: setupVerdict,
            lastHealthReason: lastHealthReason
        )
    }
}
