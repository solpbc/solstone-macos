import Foundation
import Testing
import SolstoneCore
@testable import solstone

private let statusSummaryNow = Date(timeIntervalSince1970: 1_000_000)
private let statusSummaryRecentDelivery = statusSummaryNow.addingTimeInterval(-120)
private let statusSummaryServerURL = "https://x.example:5015"

@Suite("StatusHealthSummary")
struct StatusHealthSummaryTests {
    @Test func bundledModeAlwaysReportsMigrationNeeded() {
        let summary = makeSummary(serviceMode: .bundled, isRecording: false, isPaused: true, uploadStatus: .synced)

        #expect(summary.severity == .attention)
        #expect(summary.title == "your journal needs a new link")
        #expect(summary.subtitle == "open your journal panel to connect this Mac again")
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

    @Test func observingOffRowUsesExternalSubtitle() {
        let external = makeSummary(isRecording: false)
        #expect(external.severity == .warn)
        #expect(external.axValue == "off")
        #expect(external.subtitle == "nothing is reaching x.example while sol is off")
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
        #expect(syncing.subtitle == "syncing to x.example")

        let uploading = makeSummary(uploadStatus: .uploading(segment: "s2"), pendingCount: 4)
        #expect(uploading.severity == .warn)
        #expect(uploading.axValue == "external_uploading")
        #expect(uploading.subtitle?.contains("4 more waiting") == true)

        let connecting = makeSummary(uploadStatus: .notSynced)
        #expect(connecting.severity == .warn)
        #expect(connecting.axValue == "external_connecting")
        #expect(connecting.subtitle == "reaching x.example")
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

    @Test func footerEncryptionClauseRequiresHttpsScheme() {
        #expect(externalStatusFooterText(serverURL: "https://x.example", permissionsGranted: true).contains(", encrypted"))
        #expect(!externalStatusFooterText(serverURL: "http://x.example", permissionsGranted: true).contains(", encrypted"))
        #expect(!externalStatusFooterText(serverURL: "host.example:5015", permissionsGranted: true).contains(", encrypted"))
    }

    @Test func journalHostUsesSchemeTolerantParse() {
        #expect(journalHost(nil) == "your journal")
        #expect(journalHost("") == "your journal")
        #expect(journalHost("https://x.example:5015") == "x.example")
        #expect(journalHost("x.example:5015") == "x.example")
    }

    @Test func coarseRelativeTimeBuckets() {
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(-30), now: statusSummaryNow) == "just now")
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(30), now: statusSummaryNow) == "just now")
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(-120), now: statusSummaryNow) == "2m ago")
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(-7_200), now: statusSummaryNow) == "2h ago")
        #expect(coarseRelativeTime(statusSummaryNow.addingTimeInterval(-172_800), now: statusSummaryNow) == "2d ago")
    }

    private func makeSummary(
        serviceMode: ServiceMode? = .external,
        isRecording: Bool = true,
        isPaused: Bool = false,
        uploadStatus: UploadCoordinator.Status = .synced,
        pendingCount: Int = 0,
        lastDeliveryOutcome: LastJournalDeliveryOutcome = .delivered(statusSummaryRecentDelivery),
        serverURL: String? = statusSummaryServerURL,
        now: Date = statusSummaryNow,
        setupVerdict: SetupGroupVerdict? = nil
    ) -> StatusHealthSummary {
        StatusHealthSummary.make(
            serviceMode: serviceMode,
            isRecording: isRecording,
            isPaused: isPaused,
            uploadStatus: uploadStatus,
            pendingCount: pendingCount,
            lastDeliveryOutcome: lastDeliveryOutcome,
            serverURL: serverURL,
            now: now,
            setupVerdict: setupVerdict
        )
    }
}
