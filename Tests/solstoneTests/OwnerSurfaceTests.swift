// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SolstoneCore
import Testing
@testable import solstone

@Suite("OwnerSurfaceSources")
struct OwnerSurfaceSourcesTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func browserToggleDoesNotRestartMedia() {
        #expect(sourcesToggleRestartsMedia(.microphone(false)))
        #expect(sourcesToggleRestartsMedia(.screen(true)))
        #expect(!sourcesToggleRestartsMedia(.browserPages(false)))
        #expect(!sourcesToggleRestartsMedia(.browserPages(true)))
    }

    @Test func browserOnlyPauseIsReachableWithoutMedia() {
        let pause = menuPauseControls(
            mediaRecording: false,
            mediaPaused: false,
            mediaUserPaused: false,
            pauseManagerPaused: false,
            browserCapturePermitted: true
        )
        #expect(pause.pause)
        #expect(!pause.resume)

        let resume = menuPauseControls(
            mediaRecording: false,
            mediaPaused: false,
            mediaUserPaused: false,
            pauseManagerPaused: true,
            browserCapturePermitted: true
        )
        #expect(!resume.pause)
        #expect(resume.resume)

        let idle = menuPauseControls(
            mediaRecording: false,
            mediaPaused: false,
            mediaUserPaused: false,
            pauseManagerPaused: false,
            browserCapturePermitted: false
        )
        let lockPaused = menuPauseControls(
            mediaRecording: true,
            mediaPaused: true,
            mediaUserPaused: false,
            pauseManagerPaused: false,
            browserCapturePermitted: false
        )
        #expect(!lockPaused.pause)
        #expect(!lockPaused.resume)
        #expect(!idle.pause)
        #expect(!idle.resume)
    }

    @Test func browserOnlyPauseEligibility() {
        var snapshot = BrowserHostSnapshotValue(intakeEnabled: true)
        #expect(browserCapturePermitsPause(snapshot, now: now))

        snapshot.intakeEnabled = false
        #expect(!browserCapturePermitsPause(snapshot, now: now))

        snapshot.intakeEnabled = true
        snapshot.shutdown = true
        #expect(!browserCapturePermitsPause(snapshot, now: now))

        snapshot.shutdown = false
        snapshot.quiescence = true
        #expect(!browserCapturePermitsPause(snapshot, now: now))
    }

    @Test func rowStaysLiveForPermittedBrowserIntake() {
        let base = (
            permissionsNeedAttention: false,
            errorMessage: nil as String?,
            initialPermissionCheckComplete: true,
            isRecording: false,
            isPaused: false,
            serviceMode: nil as ServiceMode?,
            syncPaused: false,
            isPairedIngestReady: false,
            uploadStatus: UploadCoordinator.Status.awaitingTunnel,
            hasJournalOnRecord: false
        )
        #expect(classifyObservationRowState(
            permissionsNeedAttention: base.permissionsNeedAttention,
            errorMessage: base.errorMessage,
            initialPermissionCheckComplete: base.initialPermissionCheckComplete,
            isRecording: base.isRecording,
            isPaused: base.isPaused,
            serviceMode: base.serviceMode,
            syncPaused: base.syncPaused,
            isPairedIngestReady: base.isPairedIngestReady,
            uploadStatus: base.uploadStatus,
            hasJournalOnRecord: base.hasJournalOnRecord
        ) == .stopped)
        #expect(classifyObservationRowState(
            permissionsNeedAttention: base.permissionsNeedAttention,
            errorMessage: base.errorMessage,
            initialPermissionCheckComplete: base.initialPermissionCheckComplete,
            isRecording: base.isRecording,
            isPaused: base.isPaused,
            serviceMode: base.serviceMode,
            syncPaused: base.syncPaused,
            isPairedIngestReady: base.isPairedIngestReady,
            uploadStatus: base.uploadStatus,
            hasJournalOnRecord: base.hasJournalOnRecord,
            browserIntakePermitted: true
        ) == .observing)
        #expect(classifyObservationRowState(
            permissionsNeedAttention: base.permissionsNeedAttention,
            errorMessage: base.errorMessage,
            initialPermissionCheckComplete: base.initialPermissionCheckComplete,
            isRecording: base.isRecording,
            isPaused: base.isPaused,
            serviceMode: base.serviceMode,
            syncPaused: base.syncPaused,
            isPairedIngestReady: base.isPairedIngestReady,
            uploadStatus: base.uploadStatus,
            hasJournalOnRecord: base.hasJournalOnRecord,
            browserIntakePaused: true
        ) == .paused)
    }

    @Test func relativeTimeUsesCalendarBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(browserRelativeTimeBucket(lastSeen: now.addingTimeInterval(-30), now: now, calendar: calendar) == .justNow)
        #expect(browserRelativeTimeBucket(lastSeen: now.addingTimeInterval(-120), now: now, calendar: calendar) == .minutes(2))
        #expect(browserRelativeTimeBucket(lastSeen: now.addingTimeInterval(-7_200), now: now, calendar: calendar) == .hours(2))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        #expect(browserRelativeTimeBucket(lastSeen: yesterday, now: now, calendar: calendar) == .yesterday)
        let older = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: now))!
        #expect(browserRelativeTimeBucket(lastSeen: older, now: now, calendar: calendar) == .date(older))
    }
}

@Suite("OwnerSurfaceStatus")
struct OwnerSurfaceStatusTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func ownerGatesOutrankCustodyAndLocalReceiptIsNotDelivered() {
        let permitted = BrowserHostSnapshotValue(capture: "permitted", delivery: "kept_locally", custodyFull: true, custodyPresent: true, listener: .available)
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: permitted, now: now) == .custodyFull)

        var lost = permitted
        lost.failureCode = "unaccepted_lost"
        lost.listener = .available
        let lostVerdict = browserOwnerVerdict(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: lost, now: now)
        #expect(lostVerdict.lead == .hold("unaccepted_lost"))
        #expect(lostVerdict.fullSecondary)

        var legacy = BrowserHostSnapshotValue(capture: "permitted", delivery: "idle", failureCode: "queue_full", listener: .available)
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: legacy, now: now) == .hold("queue_full"))
        legacy.custodyPresent = true
        legacy.custodyFull = false
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: legacy, now: now) == .hold("queue_full"))

        let exhausted = BrowserHostSnapshotValue(capture: "permitted", delivery: "failed", failureCode: "resource_exhausted", listener: .available)
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: exhausted, now: now) == .hold("resource_exhausted"))

        let exhaustedVerdict = browserOwnerVerdict(mediaSourcesEmpty: true, mediaRecording: false,
            mediaPaused: false, snapshot: exhausted, now: now)
        #expect(!exhaustedVerdict.fullSecondary)
        var independentCustody = exhausted
        independentCustody.custodyPresent = true
        independentCustody.custodyFull = true
        independentCustody.custodyStale = true
        independentCustody.failureCode = "local_io"
        let independentVerdict = browserOwnerVerdict(mediaSourcesEmpty: true, mediaRecording: false,
            mediaPaused: false, snapshot: independentCustody, now: now)
        #expect(independentVerdict.lead == .hold("local_io"))
        #expect(independentVerdict.fullSecondary)
        #expect(independentVerdict.stale)
        #expect(independentVerdict.showsDeliveryLine)

        let activeProfile = BrowserHostProfile(lastSeen: now, handshake: .compatible, byeReason: nil, leaseExpiry: now.addingTimeInterval(30))
        let stale = BrowserHostSnapshotValue(
            capture: "permitted",
            delivery: "kept_locally",
            custodyStale: true,
            custodyPresent: true,
            profiles: BrowserHostProfileGroup(chrome: [activeProfile]),
            listener: .available
        )
        let staleVerdict = browserOwnerVerdict(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: stale, now: now)
        #expect(staleVerdict.lead == .ready)
        #expect(staleVerdict.stale)
        #expect(!staleVerdict.showsDeliveryLine)
        #expect(!browserPresentsLocalReceiptAsDelivered("kept_locally"))
        #expect(statusPrimaryDelivery(media: LastJournalDeliveryOutcome.noDeliveryYet, browserDelivery: "kept_locally") == .noDeliveryYet)

        let paused = BrowserHostSnapshotValue(capture: "paused", custodyFull: true, custodyPresent: true, listener: .available)
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: paused, now: now) == .paused)
        let unpaired = BrowserHostSnapshotValue(capture: "not_paired", custodyFull: true, custodyPresent: true, listener: .available)
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: unpaired, now: now) == .notPaired)
        var shutdown = BrowserHostSnapshotValue(capture: "permitted")
        shutdown.shutdown = true
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: shutdown, now: now) == .shutdown)
    }

    @Test func sessionLeaseDoesNotTreatAbsenceAsExpiry() {
        let open = BrowserHostSnapshotValue(capture: "permitted", delivery: "idle")
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: open, now: now) == .unavailable)

        var openWithListener = open
        openWithListener.listener = .available
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: openWithListener, now: now) == .waiting)

        let seen = now.addingTimeInterval(-10)
        let valid = BrowserHostProfile(lastSeen: seen, handshake: .compatible, byeReason: nil, leaseExpiry: now.addingTimeInterval(30))
        var connected = openWithListener
        connected.profiles = BrowserHostProfileGroup(chrome: [valid])
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: connected, now: now) == .ready)

        let expired = BrowserHostProfile(lastSeen: seen, handshake: .compatible, byeReason: nil, leaseExpiry: seen)
        var closed = openWithListener
        closed.profiles = BrowserHostProfileGroup(chrome: [expired])
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: closed, now: now) == .waiting)

        let bye = BrowserHostProfile(lastSeen: seen, handshake: .compatible, byeReason: "shutdown", leaseExpiry: now.addingTimeInterval(30))
        closed.profiles = BrowserHostProfileGroup(firefox: [bye])
        #expect(browserOwnerStatusLead(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: closed, now: now) == .waiting)
    }

    @Test func localReceiptIsNotDelivered() {
        #expect(!browserPresentsLocalReceiptAsDelivered("kept_locally"))
        #expect(browserPresentsLocalReceiptAsDelivered("delivered"))
        #expect(!browserPresentsLocalReceiptAsDelivered("idle"))
        #expect(!browserPresentsLocalReceiptAsDelivered("failed"))
    }

    @Test func statusCardFooterAndSetupKeepMediaTruth() {
        let draining = BrowserHostSnapshotValue(intakeEnabled: false, capture: "intake_off", delivery: "kept_locally")
        let drainingSummary = statusSummary(snapshot: draining, recording: false, sources: [])
        #expect(drainingSummary.axValue == "browser_draining")
        #expect(drainingSummary.subtitle != UICopy.SOURCES_NONE_REASON)
        #expect(sourcesFooter(media: UICopy.SOURCES_NONE, lead: .draining) != UICopy.SOURCES_NONE_REASON)

        let validProfile = BrowserHostProfile(lastSeen: now, handshake: .compatible, byeReason: nil, leaseExpiry: now.addingTimeInterval(30))
        let ready = BrowserHostSnapshotValue(
            capture: "permitted",
            delivery: "kept_locally",
            profiles: BrowserHostProfileGroup(chrome: [validProfile]),
            listener: .available
        )
        let readySummary = statusSummary(snapshot: ready, recording: false, sources: [])
        #expect(readySummary.axValue == "browser_ready")
        #expect(readySummary.title != UICopy.SOURCES_NONE)

        let recording = statusSummary(snapshot: ready, recording: true, sources: .screen)
        #expect(recording.axValue == "external_awaiting_tunnel")
        #expect(recording.axValue != "browser_ready")

        let setup = buildSetupSnapshot(SetupSnapshotInput(
            topology: .undecided,
            solAppPlacement: .ready,
            journalAppInstalled: .ready,
            serviceIsDone: false,
            screenRecording: .notGranted,
            microphone: .notGranted,
            lastDeliveryOutcome: .noDeliveryYet,
            now: now
        ))
        #expect(setup.rows.map(\.id).contains(.screenRecording))
        #expect(setup.rows.map(\.id).contains(.microphone))
        #expect(browserSetupGroupIsVisible(screenGranted: false, microphoneGranted: false))
        #expect(sourcesFooter(media: UICopy.SOURCES_NONE, lead: .ready) == UICopy.SOURCES_BROWSER_HEADLINE_READY)
        #expect(sourcesFooter(media: UICopy.SOURCES_NONE, lead: .waiting) == UICopy.SOURCES_BROWSER_HEADLINE_WAITING)
    }

    @Test func browserOwnerLeadsMatchUnheldWhenNotRecording() {
        let validProfile = BrowserHostProfile(lastSeen: now, handshake: .compatible, byeReason: nil, leaseExpiry: now.addingTimeInterval(30))

        var shutdownSnap = BrowserHostSnapshotValue(capture: "permitted")
        shutdownSnap.shutdown = true

        let leadSnapshots: [(BrowserHostSnapshotValue, BrowserOwnerStatusLead)] = [
            (BrowserHostSnapshotValue(intakeEnabled: false, capture: "intake_off", delivery: "kept_locally"), .draining),
            (shutdownSnap, .shutdown),
            (BrowserHostSnapshotValue(capture: "paused", listener: .available), .paused),
            (BrowserHostSnapshotValue(capture: "not_paired", listener: .available), .notPaired),
            (BrowserHostSnapshotValue(capture: "unavailable", listener: .available), .unavailable),
            (BrowserHostSnapshotValue(intakeEnabled: false, capture: "intake_off", delivery: "idle"), .intakeOff),
            (BrowserHostSnapshotValue(capture: "permitted", delivery: "idle", failureCode: "queue_full", listener: .available), .hold("queue_full")),
            (BrowserHostSnapshotValue(capture: "permitted", delivery: "kept_locally", custodyFull: true, custodyPresent: true, listener: .available), .custodyFull),
            (BrowserHostSnapshotValue(capture: "permitted", delivery: "idle", listener: .available), .waiting),
            (BrowserHostSnapshotValue(capture: "permitted", delivery: "idle", profiles: BrowserHostProfileGroup(chrome: [validProfile]), listener: .available), .ready),
            (BrowserHostSnapshotValue(intakeEnabled: true, capture: "other"), .unknown),
            (BrowserHostSnapshotValue(intakeEnabled: false, capture: "other"), .mediaUnchanged)
        ]

        for (snapshot, expectedLead) in leadSnapshots {
            let verdict = browserOwnerVerdict(mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false, snapshot: snapshot, now: now)
            #expect(verdict.lead == expectedLead)

            let heldSummary = statusSummary(snapshot: snapshot, recording: false, sources: [], held: true)
            let unheldSummary = statusSummary(snapshot: snapshot, recording: false, sources: [], held: false)
            #expect(heldSummary == unheldSummary)
        }
    }

    private func statusSummary(
        snapshot: BrowserHostSnapshotValue,
        recording: Bool,
        sources: CaptureSources,
        held: Bool = false
    ) -> StatusHealthSummary {
        StatusHealthSummary.makeIncludingBrowser(
            serviceMode: nil,
            isRecording: recording,
            isPaused: false,
            held: held,
            uploadStatus: .awaitingTunnel,
            pendingCount: 0,
            lastDeliveryOutcome: .noDeliveryYet,
            serverURL: nil,
            now: now,
            selectedSources: sources,
            permittedSources: sources,
            snapshot: snapshot
        )
    }
}

@Suite("OwnerSurfaceRepair")
struct OwnerSurfaceRepairTests {
    @Test func repairCoalescesAndIgnoresAStaleGeneration() {
        var controller = BrowserRepairController()
        let first = controller.click()
        #expect(first != nil)
        #expect(controller.click() == nil)
        let ready = registrationReport(state: .ready)
        controller.complete(token: first!, report: ready, listenerHoldsFence: true, endpoint: .live)
        #expect(controller.repaired)
        #expect(controller.results[.chrome]?.state == .ready)

        let kept = controller.results
        let second = controller.click()
        controller.viewGeneration += 1
        controller.complete(token: second!, report: registrationReport(state: .refused), listenerHoldsFence: false, endpoint: .refused)
        #expect(controller.results == kept)
        #expect(!controller.repaired)
        #expect(!controller.inFlight)

        let third = controller.click()
        controller.lifecycleGeneration += 1
        controller.complete(token: third!, report: registrationReport(state: .changed), listenerHoldsFence: false, endpoint: .removed)
        #expect(controller.results == kept)

        let fourth = controller.click()
        controller.destinationGeneration += 1
        controller.complete(token: fourth!, report: registrationReport(state: .changed), listenerHoldsFence: false, endpoint: .absent)
        #expect(controller.results == kept)
    }

    @Test func repairWithoutTheListenerFenceRequiresACleanEndpoint() {
        var controller = BrowserRepairController()
        let token = controller.click()!
        controller.complete(token: token, report: registrationReport(state: .changed), listenerHoldsFence: false, endpoint: .live)
        #expect(!controller.repaired)
        let again = controller.click()!
        controller.complete(token: again, report: registrationReport(state: .changed), listenerHoldsFence: true, endpoint: .removed)
        #expect(controller.repaired)
    }

    @Test func storeOpenStaysDisabledUntilAVerifiedDestinationExists() {
        var called = false
        let disabled = performBrowserStoreOpen(brand: .firefox, catalog: .preview) { _, _ in
            called = true
            return true
        }
        #expect(disabled == .disabled)
        #expect(!called)

        let catalog = BrowserStoreCatalog(urls: [.firefox: URL(string: "https://example.invalid/listing")!])
        var seen: URL?
        let failed = performBrowserStoreOpen(brand: .firefox, catalog: catalog) { url, brand in
            seen = url
            #expect(brand == .firefox)
            return false
        }
        #expect(failed == .failed)
        #expect(seen?.query == nil)
        #expect(failed != .opened)
    }

    @Test func diagnosticsOmitPageMaterialAndStayVisibleWithoutMediaGrants() {
        let seen = Date(timeIntervalSince1970: 1_700_000_000 - 90)
        let profile = BrowserHostProfile(lastSeen: seen, handshake: .compatible, byeReason: nil, leaseExpiry: seen.addingTimeInterval(30))
        let snapshot = BrowserHostSnapshotValue(
            capture: "permitted",
            delivery: "kept_locally",
            custodyStale: true,
            custodyPresent: true,
            profiles: BrowserHostProfileGroup(chrome: [profile]),
            listener: .collision
        )
        let rows = buildBrowserDiagnosticRows(snapshot: snapshot, repair: BrowserRepairController(), now: Date(timeIntervalSince1970: 1_700_000_000))
        let text = rows.map { "\($0.label) \($0.humanValue) \($0.machineValue)" }.joined(separator: "\n")
        #expect(!text.contains("http"))
        #expect(!text.contains("host.sock"))
        #expect(!text.contains("/"))
        #expect(rows.contains { $0.machineValue.contains("Chrome") })
        #expect(browserSetupGroupIsVisible(screenGranted: false, microphoneGranted: false))
    }

    private func registrationReport(state: BrowserHostRegistrationState) -> BrowserHostRegistrationReport {
        let outcomes = Dictionary(uniqueKeysWithValues: BrowserBrand.allCases.map { brand in
            (brand, BrowserHostRegistrationOutcome(brand: brand, state: state, path: nil, reasonCode: state == .refused ? "unsafe_manifest" : nil))
        })
        return BrowserHostRegistrationReport(outcomes: outcomes, changedAny: state == .changed)
    }
}

#endif
