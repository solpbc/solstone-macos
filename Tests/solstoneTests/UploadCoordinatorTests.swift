// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
import SolstoneCore
@testable import solstone

@Suite("UploadCoordinator", .serialized)
@MainActor
struct UploadCoordinatorTests {
    private let store = ObserverURLProtocolStore()

    @Test func syncCompleteDoesNotUpdateLastSyncedAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed)

        coordinator.handleProgressEvent(.syncComplete)

        #expect(coordinator.lastSyncedAt == nil)
    }

    @Test func segmentUnprovableRecordsEvidenceOnceThenCoalescesOnRepeat() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = DiagnosticEvidenceHarness()
        let coordinator = try makeCoordinator(now: fixed, recorder: harness.recorder)

        coordinator.handleProgressEvent(.segmentUnprovable(segment: "130000_300"))
        coordinator.handleProgressEvent(.segmentUnprovable(segment: "130000_300"))

        let entries = await harness.entries()
        #expect(evidenceCodes(entries) == [.syncSegmentUnprovable])
        #expect(entries.first?.repeatCount == 2)
    }

    @Test func journalContactSucceededUpdatesLastSyncedAtAndResetsHealthErrors() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed)

        coordinator.handleProgressEvent(.uploadFailed(
            segment: "x",
            error: "raw failure",
            healthReason: .uploadFailed
        ))
        coordinator.handleProgressEvent(.journalContactSucceeded)

        #expect(coordinator.lastSyncedAt == fixed)
        #expect(coordinator.recentErrorCount == 0)
        #expect(coordinator.lastError == nil)
        #expect(coordinator.lastErrorReason == nil)
    }

    @Test func journalContactSucceededWritesDurableLastContactPayload() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_001)
        let root = try makeTempDirectory("upload-coordinator-last-contact")
        let store = InMemoryLastSuccessfulJournalContactStore()
        let fingerprint = JournalConnectionFingerprint(value: "sha256:current")
        let coordinator = UploadCoordinator(
            forSnapshot: StorageManager(baseDirectory: root),
            config: AppConfig(serverURL: "https://journal.example", serverKey: "secret", serviceMode: .external),
            lastContactStore: store,
            journalIdentityProvider: { .identified(fingerprint) }
        )
        coordinator.nowProvider = { fixed }

        coordinator.handleProgressEvent(.journalContactSucceeded)

        #expect(store.read() == .found(LastSuccessfulJournalContactPayload(
            date: fixed,
            fingerprint: fingerprint.value
        )))
        #expect(coordinator.lastSuccessfulJournalContactOutcome == .synced(fixed))
    }

    @Test func recentErrorCountIncrementsClampsAndResetsOnJournalContact() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed)

        coordinator.handleProgressEvent(.uploadFailed(
            segment: "x",
            error: "upload failed",
            healthReason: .uploadFailed
        ))
        coordinator.handleProgressEvent(.offline(
            error: "offline",
            healthReason: .urlErrorCode(URLError.notConnectedToInternet.rawValue)
        ))

        #expect(coordinator.recentErrorCount == 2)
        #expect(coordinator.lastErrorReason == "url_error_-1009")

        for _ in 0..<120 {
            coordinator.handleProgressEvent(.uploadFailed(
                segment: "x",
                error: "upload failed",
                healthReason: .uploadFailed
            ))
        }

        #expect(coordinator.recentErrorCount == 99)

        coordinator.handleProgressEvent(.journalContactSucceeded)
        #expect(coordinator.recentErrorCount == 0)
        #expect(coordinator.lastErrorReason == nil)
    }

    @Test func lastErrorReasonUsesTypedSanitizedTokens() throws {
        let coordinator = try makeCoordinator(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        coordinator.handleProgressEvent(.offline(
            error: "timed out",
            healthReason: observerHealthFailureReason(from: URLError(.timedOut))
        ))
        #expect(coordinator.lastErrorReason == "url_error_-1001")

        coordinator.handleProgressEvent(.uploadFailed(
            segment: "x",
            error: "server failed",
            healthReason: observerHealthFailureReason(from: UploadError.serverError(statusCode: 503, message: "body"))
        ))
        #expect(coordinator.lastErrorReason == "http_503")

        coordinator.handleProgressEvent(.uploadFailed(
            segment: "143022_300",
            error: "/tmp/private/143022_300/file.mp4?token=secret",
            healthReason: .uploadFailed
        ))
        #expect(coordinator.lastError == "/tmp/private/143022_300/file.mp4?token=secret")
        #expect(coordinator.lastErrorReason == "upload_failed")
        #expect(coordinator.lastErrorReason?.contains("143022_300") == false)
        #expect(coordinator.lastErrorReason?.contains("/tmp/private") == false)
        #expect(coordinator.lastErrorReason?.contains("token") == false)
        #expect(coordinator.lastErrorReason?.contains("secret") == false)
    }

    @Test func awaitingTunnelDoesNotChangeErrorStateOrRetryBudget() throws {
        let coordinator = try makeCoordinator(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        coordinator.recentErrorCount = 7
        coordinator.lastError = "existing error"
        coordinator.lastErrorReason = "existing_reason"

        coordinator.handleProgressEvent(.awaitingTunnel)

        #expect(coordinator.status == .awaitingTunnel)
        #expect(coordinator.recentErrorCount == 7)
        #expect(coordinator.lastError == "existing error")
        #expect(coordinator.lastErrorReason == "existing_reason")
    }

    @Test func syncOnStartupWaitsForInitialConfigurationBeforeSyncing() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("upload-coordinator-startup")
        let segment = try makeSegment(root: root)
        let sha = try #require(UploadClient().sha256(
            of: segment.url.appendingPathComponent("\(segment.url.lastPathComponent)_audio.m4a")
        ))
        let day = dayString(for: segment.date)
        let filename = "\(segment.url.lastPathComponent)_audio.m4a"
        store.enqueue(statusCode: 200, body: #"{"days":{"\#(day)":{"segments":1}}}"#)
        store.enqueue(statusCode: 200, body: #"{"version":1,"day":"\#(day)","segments":{"\#(segment.url.lastPathComponent)":{"files":[{"name":"audio.m4a","submitted_name":"\#(filename)","sha256":"\#(sha)","size":5,"status":"present"}]}}}"#)
        store.enqueue(statusCode: 200, body: #"{"protocol_version":3,"total":1,"items":[{"key":"\#(segment.url.lastPathComponent)","observed":true,"files":[{"name":"audio.m4a","submitted_name":"\#(filename)","sha256":"\#(sha)","size":5,"status":"present"}]}]}"#)
        let pairing = TunnelPairingIdentity(instanceID: "instance", fingerprint: "fingerprint")
        let coordinator = UploadCoordinator(
            storageManager: StorageManager(baseDirectory: root),
            config: AppConfig(serverURL: "https://configured.example", serverKey: "secret"),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24692") },
            pairedIngestIdentity: pairing,
            journalIdentityProvider: { .identified(tunnelJournalConnectionFingerprint(for: pairing)) }
        )

        let syncTask = Task {
            await coordinator.syncOnStartup()
        }
        await store.waitForRequestCount(3)
        await syncTask.value

        let request = try #require(store.snapshotRequests().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == IngestProtocolV3.manifestPath)
    }

    @Test func nonDeliveryEventsNeverCreateDeliveryFact() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = canonicalDeliveryFingerprint()
        let delivery = InMemoryLastJournalDeliveryStore()
        let contact = InMemoryLastSuccessfulJournalContactStore()
        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .identified(fingerprint),
            contact: contact
        )

        #expect(delivery.read() == .absent)
        #expect(coordinator.lastJournalDeliveryOutcome == .noDeliveryYet)

        for event in Self.nonDeliveryProgressEvents {
            coordinator.handleProgressEvent(event)
            #expect(delivery.read() == .absent)
            #expect(coordinator.lastJournalDeliveryOutcome == .noDeliveryYet)
            if case .journalContactSucceeded = event {
                #expect(contact.read() == .found(LastSuccessfulJournalContactPayload(
                    date: now,
                    fingerprint: fingerprint.value
                )))
                #expect(coordinator.lastSuccessfulJournalContactOutcome == .synced(now))
            }
        }
    }

    @Test func nonDeliveryEventsPreserveEstablishedDelivery() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = canonicalDeliveryFingerprint()
        let delivery = InMemoryLastJournalDeliveryStore()
        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .identified(fingerprint)
        )
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))
        let established = LastJournalDeliveryPayload(date: now, fingerprint: fingerprint.value)
        #expect(delivery.read() == .found(established))
        #expect(coordinator.lastJournalDeliveryOutcome == .delivered(now))

        for event in Self.nonDeliveryProgressEvents {
            coordinator.handleProgressEvent(event)
            #expect(delivery.read() == .found(established))
            #expect(coordinator.lastJournalDeliveryOutcome == .delivered(now))
        }
    }

    @Test func nonSuccessEventsDoNotClearWriteFailureFlag() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = canonicalDeliveryFingerprint()
        let delivery = InMemoryLastJournalDeliveryStore(writeResult: .failed)
        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .identified(fingerprint)
        )

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))
        #expect(coordinator.lastJournalDeliveryWriteFailed == true)
        #expect(coordinator.lastJournalDeliveryOutcome == .unavailable)
        #expect(delivery.read() == .absent)

        coordinator.handleProgressEvent(.journalContactSucceeded)
        #expect(coordinator.lastJournalDeliveryWriteFailed == true)
        #expect(coordinator.lastJournalDeliveryOutcome == .unavailable)
        #expect(delivery.read() == .absent)

        coordinator.handleProgressEvent(.syncComplete)
        #expect(coordinator.lastJournalDeliveryWriteFailed == true)
        #expect(coordinator.lastJournalDeliveryOutcome == .unavailable)
        #expect(delivery.read() == .absent)

        delivery.writeResult = .confirmed
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))
        #expect(coordinator.lastJournalDeliveryWriteFailed == false)
        #expect(coordinator.lastJournalDeliveryOutcome == .delivered(now))
    }

    @Test func failedDeliveryAlwaysRecordsAndNoticeRearmsAfterConfirmedWrite() async throws {
        let harness = DiagnosticEvidenceHarness()
        let events = UploadDiagnosticEvents()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = canonicalDeliveryFingerprint()
        let delivery = InMemoryLastJournalDeliveryStore(writeResult: .failed)
        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .identified(fingerprint),
            recorder: harness.recorder,
            logAdapter: DiagnosticEvidenceLoggingAdapter { events.events.append($0) }
        )

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))

        var entries = await harness.entries()
        #expect(evidenceCodes(entries) == [.deliveryWriteFailed])
        #expect(entries[0].repeatCount == 2)
        #expect(events.events == [.deliveryWriteFailed])

        delivery.writeResult = .confirmed
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))
        delivery.writeResult = .failed
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))

        entries = await harness.entries()
        #expect(evidenceCodes(entries) == [.deliveryWriteFailed])
        #expect(entries[0].repeatCount == 3)
        #expect(events.events == [.deliveryWriteFailed, .deliveryWriteFailed])
    }

    @Test func absentAndMismatchedProofDoNotConsumeDeliveryFailureEdge() async throws {
        let harness = DiagnosticEvidenceHarness()
        let events = UploadDiagnosticEvents()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let matching = canonicalDeliveryFingerprint()
        let mismatched = canonicalDeliveryFingerprint("mismatched")
        let identity = MutableJournalIdentityRead(.absent)
        let delivery = InMemoryLastJournalDeliveryStore(writeResult: .failed)

        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .absent,
            identityProvider: { identity.value },
            recorder: harness.recorder,
            logAdapter: DiagnosticEvidenceLoggingAdapter { events.events.append($0) }
        )
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "segment", journalFingerprint: matching.value))
        #expect(!coordinator.lastJournalDeliveryWriteFailed)
        #expect(evidenceCodes(await harness.entries()).isEmpty)
        #expect(events.events.isEmpty)

        identity.value = .identified(matching)
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "segment", journalFingerprint: mismatched.value))
        #expect(!coordinator.lastJournalDeliveryWriteFailed)
        #expect(evidenceCodes(await harness.entries()).isEmpty)
        #expect(events.events.isEmpty)

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "segment", journalFingerprint: matching.value))
        #expect(coordinator.lastJournalDeliveryWriteFailed)
        #expect(evidenceCodes(await harness.entries()) == [.deliveryWriteFailed])
        #expect(events.events == [.deliveryWriteFailed])
    }

    @Test func nonDeliveryAndConfirmedDeliveryEventsStaySilentInAdapter() throws {
        let events = UploadDiagnosticEvents()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = canonicalDeliveryFingerprint()
        let delivery = InMemoryLastJournalDeliveryStore()
        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .identified(fingerprint),
            logAdapter: DiagnosticEvidenceLoggingAdapter { events.events.append($0) }
        )

        coordinator.handleProgressEvent(.journalContactSucceeded)
        coordinator.handleProgressEvent(.syncComplete)
        coordinator.handleProgressEvent(.uploadRetrying(segment: "x", attempt: 1))
        coordinator.handleProgressEvent(.offline(error: "offline", healthReason: .urlErrorCode(-1009)))
        coordinator.handleProgressEvent(.uploadFailed(segment: "x", error: "failed", healthReason: .uploadFailed))
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))

        #expect(events.events.isEmpty)
    }

    @Test func matchingProofWritesDeliveryPayload() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = canonicalDeliveryFingerprint()
        let delivery = InMemoryLastJournalDeliveryStore()
        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .identified(fingerprint)
        )

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))

        #expect(delivery.read() == .found(LastJournalDeliveryPayload(
            date: now,
            fingerprint: fingerprint.value
        )))
        #expect(coordinator.lastJournalDeliveryOutcome == .delivered(now))
        #expect(coordinator.lastJournalDeliveryWriteFailed == false)
    }

    @Test func mismatchedOrFailedIdentityDoesNotWrite() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = canonicalDeliveryFingerprint("stored")
        let current = canonicalDeliveryFingerprint("current")
        let prior = LastJournalDeliveryPayload(date: Date(timeIntervalSince1970: 50), fingerprint: stored.value)
        let delivery = InMemoryLastJournalDeliveryStore(readResult: .found(prior))
        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .identified(current)
        )

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: stored.value))
        #expect(delivery.read() == .found(prior))
        #expect(coordinator.lastJournalDeliveryOutcome == .noDeliveryYet)

        let failedDelivery = InMemoryLastJournalDeliveryStore(readResult: .found(prior))
        let failedCoordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: failedDelivery,
            identity: .failed
        )
        failedCoordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: stored.value))
        #expect(failedDelivery.read() == .found(prior))
        #expect(failedCoordinator.lastJournalDeliveryOutcome == .unavailable)

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: current.value))
        #expect(delivery.read() == .found(LastJournalDeliveryPayload(date: now, fingerprint: current.value)))
    }

    @Test func rejectedWriteSetsFailureFlagUntilConfirmedWrite() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = canonicalDeliveryFingerprint()
        let delivery = InMemoryLastJournalDeliveryStore(writeResult: .failed)
        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .identified(fingerprint)
        )

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))

        #expect(delivery.read() == .absent)
        #expect(coordinator.lastJournalDeliveryWriteFailed == true)
        #expect(coordinator.lastJournalDeliveryOutcome == .unavailable)

        delivery.writeResult = .confirmed
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))

        #expect(coordinator.lastJournalDeliveryWriteFailed == false)
        #expect(coordinator.lastJournalDeliveryOutcome == .delivered(now))
    }

    @Test func confirmedUserDefaultsDeliverySurvivesRestartWithFixedClock() throws {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = canonicalDeliveryFingerprint()
        let store = UserDefaultsLastJournalDeliveryStore(defaults: isolated.defaults)
        let root = try makeTempDirectory("upload-coordinator-delivery-restart")
        let coordinator = UploadCoordinator(
            forSnapshot: StorageManager(baseDirectory: root),
            config: AppConfig(),
            lastDeliveryStore: store,
            journalIdentityProvider: { .identified(fingerprint) }
        )
        coordinator.nowProvider = { now }
        coordinator.refreshLastJournalDelivery()

        #expect(coordinator.lastJournalDeliveryOutcome == .noDeliveryYet)

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))
        #expect(coordinator.lastJournalDeliveryOutcome == .delivered(now))
        #expect(store.read() == .found(LastJournalDeliveryPayload(date: now, fingerprint: fingerprint.value)))

        let restarted = UploadCoordinator(
            forSnapshot: StorageManager(baseDirectory: root),
            config: AppConfig(),
            lastDeliveryStore: UserDefaultsLastJournalDeliveryStore(defaults: isolated.defaults),
            journalIdentityProvider: { .identified(fingerprint) }
        )
        restarted.nowProvider = { now }
        restarted.refreshLastJournalDelivery()
        #expect(restarted.lastJournalDeliveryOutcome == .delivered(now))
    }

    @Test func invalidStorageStaysUnavailableUntilProvenDelivery() throws {
        let now = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let fingerprint = canonicalDeliveryFingerprint()
        let stale = LastJournalDeliveryPayload(date: later, fingerprint: fingerprint.value)
        let delivery = InMemoryLastJournalDeliveryStore(readResult: .found(stale))
        let coordinator = try makeDeliveryCoordinator(
            now: now,
            delivery: delivery,
            identity: .identified(fingerprint)
        )

        #expect(coordinator.lastJournalDeliveryOutcome == .unavailable)
        coordinator.refreshLastJournalDelivery()
        #expect(coordinator.lastJournalDeliveryOutcome == .unavailable)
        #expect(delivery.read() == .found(stale))

        coordinator.nowProvider = { later }
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value))
        #expect(delivery.read() == .found(LastJournalDeliveryPayload(date: later, fingerprint: fingerprint.value)))
        #expect(coordinator.lastJournalDeliveryOutcome == .delivered(later))
    }

    private static let nonDeliveryProgressEvents: [SyncService.ProgressEvent] = [
        .syncStarted,
        .syncProgress(checked: 1, total: 2),
        .uploadStarted(segment: "x"),
        .uploadRetrying(segment: "x", attempt: 2),
        .uploadFailed(segment: "x", error: "failed", healthReason: .uploadFailed),
        .journalContactSucceeded,
        .syncComplete,
        .offline(error: "offline", healthReason: .urlErrorCode(-1009)),
        .awaitingTunnel
    ]

    private func makeDeliveryCoordinator(
        now: Date,
        delivery: InMemoryLastJournalDeliveryStore,
        identity: JournalIdentityRead,
        identityProvider: (@MainActor @Sendable () -> JournalIdentityRead)? = nil,
        contact: InMemoryLastSuccessfulJournalContactStore = InMemoryLastSuccessfulJournalContactStore(),
        recorder: DiagnosticEvidenceRecorder = .dormant,
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live
    ) throws -> UploadCoordinator {
        let root = try makeTempDirectory("upload-coordinator-delivery")
        let coordinator = UploadCoordinator(
            forSnapshot: StorageManager(baseDirectory: root),
            config: AppConfig(),
            lastContactStore: contact,
            lastDeliveryStore: delivery,
            journalIdentityProvider: identityProvider ?? { identity },
            recorder: recorder,
            logAdapter: logAdapter
        )
        coordinator.nowProvider = { now }
        coordinator.refreshLastJournalDelivery()
        return coordinator
    }

    private func makeSegment(
        root: URL,
        date: Date = Date(),
        segmentName: String = "120000_300"
    ) throws -> (url: URL, date: Date) {
        let dayDir = root.appendingPathComponent(dateFolderString(for: date), isDirectory: true)
        let segmentURL = dayDir.appendingPathComponent(segmentName, isDirectory: true)
        try FileManager.default.createDirectory(at: segmentURL, withIntermediateDirectories: true)
        let audioURL = segmentURL.appendingPathComponent("\(segmentName)_audio.m4a")
        try Data("audio".utf8).write(to: audioURL)
        return (segmentURL, date)
    }

    private func dateFolderString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func dayString(for date: Date) -> String {
        dateFolderString(for: date).replacingOccurrences(of: "-", with: "")
    }

    private func resetSyncedDaysCache() {
        UserDefaults.standard.removeObject(forKey: "syncedDays")
    }

    private func makeCoordinator(
        now: Date,
        recorder: DiagnosticEvidenceRecorder = .dormant
    ) throws -> UploadCoordinator {
        let root = try makeTempDirectory("upload-coordinator")
        let coordinator = UploadCoordinator(
            forSnapshot: StorageManager(baseDirectory: root),
            config: AppConfig(),
            recorder: recorder
        )
        coordinator.nowProvider = { now }
        return coordinator
    }

    private func canonicalDeliveryFingerprint(_ distinct: String = "a") -> JournalConnectionFingerprint {
        journalConnectionFingerprint(
            config: AppConfig(
                serverURL: "https://\(distinct).example.test",
                serverKey: "key-\(distinct)",
                serviceMode: .external
            ),
            topology: .remote,
            isTunnelManaged: false,
            tunnelPairing: nil
        )!
    }
}

@MainActor
private final class UploadDiagnosticEvents {
    var events: [DiagnosticEvidenceLogEvent] = []
}

@MainActor
private final class MutableJournalIdentityRead {
    var value: JournalIdentityRead

    init(_ value: JournalIdentityRead) {
        self.value = value
    }
}
