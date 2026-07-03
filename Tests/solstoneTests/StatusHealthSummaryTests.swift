import Foundation
import Testing
import SolstoneCore
@testable import solstone

private let statusSummaryNow = Date(timeIntervalSince1970: 1_000_000)
private let statusSummaryRecentSync = statusSummaryNow.addingTimeInterval(-120)
private let statusSummaryServerURL = "https://x.example:5015"

@Suite("StatusHealthSummary")
struct StatusHealthSummaryTests {
    @Test func bundledAttentionRowsMapStoppedAndUnknown() {
        for status in [
            JournalRuntimeStatus.stopped(diagnostic("down")),
            .unknown(diagnostic("unclear"))
        ] {
            let summary = makeSummary(serviceMode: .bundled, journalRuntimeStatus: status)

            #expect(summary.severity == .attention)
            #expect(summary.axValue == "bundled_needs_attention")
            #expect(summary.subtitle?.contains("new memory is safe on this Mac") == true)
        }
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
        #expect(empty.subtitle == "nothing is lost — sync resumes when it's back")
        #expect(empty.subtitle?.contains("MB") == false)
        #expect(empty.subtitle?.contains("bytes") == false)
    }

    @Test func bundledSetupStoppedAndRestartingRowsMapBeforeCaptureFlags() {
        let setup = makeSummary(serviceMode: .bundled, journalRuntimeStatus: .setupNeeded)
        #expect(setup.severity == .warn)
        #expect(setup.axValue == "bundled_setup_needed")
        #expect(setup.subtitle?.contains("finish installing") == true)

        let stopped = makeSummary(serviceMode: .bundled, journalRuntimeStatus: .stoppedByUser)
        #expect(stopped.severity == .warn)
        #expect(stopped.axValue == "bundled_stopped_by_user")
        #expect(stopped.subtitle?.contains("start it again") == true)

        let restarting = makeSummary(serviceMode: .bundled, journalRuntimeStatus: .restarting)
        #expect(restarting.severity == .warn)
        #expect(restarting.axValue == "bundled_restarting")
        #expect(restarting.subtitle == nil)
    }

    @Test func observingOffRowUsesModeSpecificSubtitle() {
        let bundled = makeSummary(serviceMode: .bundled, isRecording: false)
        #expect(bundled.severity == .warn)
        #expect(bundled.axValue == "observing_off")
        #expect(bundled.subtitle == "your journal is fine — turn sol back on to keep building memory")

        let external = makeSummary(isRecording: false)
        #expect(external.severity == .warn)
        #expect(external.axValue == "observing_off")
        #expect(external.subtitle == "nothing is reaching x.example while sol is off")
    }

    @Test func pausedRowUsesModeAndSyncSpecificSubtitle() {
        let bundled = makeSummary(serviceMode: .bundled, isPaused: true)
        #expect(bundled.severity == .warn)
        #expect(bundled.axValue == "observing_paused")
        #expect(bundled.subtitle == "journal healthy on this Mac")

        let synced = makeSummary(isPaused: true, uploadStatus: .synced)
        #expect(synced.severity == .warn)
        #expect(synced.axValue == "observing_paused")
        #expect(synced.subtitle == "synced to x.example")

        let connecting = makeSummary(isPaused: true, uploadStatus: .notSynced)
        #expect(connecting.severity == .warn)
        #expect(connecting.axValue == "observing_paused")
        #expect(connecting.subtitle == "paused — x.example")
    }

    @Test func externalInProgressRowsMapToWarningStates() {
        let retrying = makeSummary(uploadStatus: .retrying(segment: "s1", attempts: 2), pendingCount: 2)
        #expect(retrying.severity == .warn)
        #expect(retrying.axValue == "external_retrying")
        #expect(retrying.subtitle?.contains("2 segments waiting") == true)

        let syncing = makeSummary(uploadStatus: .syncing(checked: 2, total: 5))
        #expect(syncing.severity == .warn)
        #expect(syncing.axValue == "external_syncing")
        #expect(syncing.title == "catching up — 2 of 5 segments")
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

    @Test func healthyRowsMapToGoodStates() {
        let bundled = makeSummary(serviceMode: .bundled)
        #expect(bundled.severity == .good)
        #expect(bundled.axValue == "bundled_healthy")
        #expect(bundled.subtitle == "everything stays on this Mac")

        let external = makeSummary(uploadStatus: .synced, lastSyncedAt: statusSummaryRecentSync)
        #expect(external.severity == .good)
        #expect(external.axValue == "external_synced")
        #expect(external.subtitle?.contains("last synced 2m ago") == true)
    }

    @Test func externalSyncedOnlyComesFromSyncedUploadStatus() {
        let synced = makeSummary(uploadStatus: .synced)
        #expect(synced.severity == .good)
        #expect(synced.axValue == "external_synced")

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

    @Test func captureFlagsLoseToRedRowsAndTableOrderedBundledRows() {
        let uploadingOff = makeSummary(isRecording: false, uploadStatus: .uploading(segment: "s1"))
        #expect(uploadingOff.axValue == "observing_off")

        let bundledOff = makeSummary(serviceMode: .bundled, isRecording: false)
        #expect(bundledOff.axValue == "observing_off")

        let syncedPaused = makeSummary(isPaused: true, uploadStatus: .synced)
        #expect(syncedPaused.axValue == "observing_paused")

        let stoppedPaused = makeSummary(
            serviceMode: .bundled,
            isPaused: true,
            journalRuntimeStatus: .stopped(diagnostic("down"))
        )
        #expect(stoppedPaused.axValue == "bundled_needs_attention")

        let offlinePaused = makeSummary(isPaused: true, uploadStatus: .offline("offline"))
        #expect(offlinePaused.axValue == "external_offline")

        // Journal rows 3-5 precede capture flags in the table.
        let setupOff = makeSummary(serviceMode: .bundled, isRecording: false, journalRuntimeStatus: .setupNeeded)
        #expect(setupOff.axValue == "bundled_setup_needed")

        let restartingOff = makeSummary(serviceMode: .bundled, isRecording: false, journalRuntimeStatus: .restarting)
        #expect(restartingOff.axValue == "bundled_restarting")
    }

    @Test func externalHealthySubtitleDoesNotFabricateTimeOrBytes() {
        let justConnected = makeSummary(uploadStatus: .synced, lastSyncedAt: nil)
        #expect(justConnected.subtitle == "just connected to x.example")

        let nothingWaiting = makeSummary(uploadStatus: .synced, pendingCount: 0, lastSyncedAt: statusSummaryRecentSync)
        #expect(nothingWaiting.subtitle?.hasSuffix(" · nothing waiting") == true)

        let waiting = makeSummary(uploadStatus: .synced, pendingCount: 5, lastSyncedAt: statusSummaryRecentSync)
        #expect(waiting.subtitle?.contains(" · 5 waiting") == true)
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
        journalRuntimeStatus: JournalRuntimeStatus = .running,
        uploadStatus: UploadCoordinator.Status = .synced,
        pendingCount: Int = 0,
        lastSyncedAt: Date? = nil,
        serverURL: String? = statusSummaryServerURL,
        now: Date = statusSummaryNow
    ) -> StatusHealthSummary {
        StatusHealthSummary.make(
            serviceMode: serviceMode,
            isRecording: isRecording,
            isPaused: isPaused,
            journalRuntimeStatus: journalRuntimeStatus,
            uploadStatus: uploadStatus,
            pendingCount: pendingCount,
            lastSyncedAt: lastSyncedAt,
            serverURL: serverURL,
            now: now
        )
    }

    private func diagnostic(_ message: String) -> JournalDiagnostic {
        JournalDiagnostic(commandLabel: "journal health", outputExcerpt: message)
    }
}
