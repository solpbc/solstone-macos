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

    @Test func bundledAvailableUploadSucceededRecordsLastIngestAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: true)

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x"))

        #expect(coordinator.bundledJournalLastIngestAt == fixed)
    }

    @Test func bundledAvailableBeforeAnyUploadHasNoLastIngestAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: true)

        #expect(coordinator.bundledJournalLastIngestAt == nil)
    }

    @Test func unavailableUploadSucceededDoesNotExposeLastIngestAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: false)

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x"))

        #expect(coordinator.bundledJournalLastIngestAt == nil)

        coordinator.bundledAvailabilityProvider = { true }
        #expect(coordinator.bundledJournalLastIngestAt == nil)
    }

    @Test func syncCompleteWithoutUploadDoesNotSetBundledLastIngestAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: true)

        coordinator.handleProgressEvent(.syncComplete)

        #expect(coordinator.bundledJournalLastIngestAt == nil)
    }

    @Test func syncCompleteDoesNotUpdateLastSyncedAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: false)

        coordinator.handleProgressEvent(.syncComplete)

        #expect(coordinator.bundledJournalLastIngestAt == nil)
        #expect(coordinator.lastSyncedAt == nil)
    }

    @Test func journalContactSucceededUpdatesLastSyncedAtAndResetsHealthErrors() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: false)

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

    @Test func uploadFailedDoesNotSetBundledLastIngestAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: true)

        coordinator.handleProgressEvent(.uploadFailed(
            segment: "x",
            error: "offline",
            healthReason: .uploadFailed
        ))

        #expect(coordinator.bundledJournalLastIngestAt == nil)
    }

    @Test func uploadFailedAfterSuccessDoesNotClearLastIngestAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: true)

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x"))
        coordinator.handleProgressEvent(.uploadFailed(
            segment: "x",
            error: "offline",
            healthReason: .uploadFailed
        ))

        #expect(coordinator.bundledJournalLastIngestAt == fixed)
    }

    @Test func gateFlipHidesAndReExposesStoredLastIngestAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: true)

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x"))
        #expect(coordinator.bundledJournalLastIngestAt == fixed)

        coordinator.bundledAvailabilityProvider = { false }
        #expect(coordinator.bundledJournalLastIngestAt == nil)

        coordinator.bundledAvailabilityProvider = { true }
        #expect(coordinator.bundledJournalLastIngestAt == fixed)
    }

    @Test func laterUploadSucceededAdvancesLastIngestAt() throws {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = Date(timeIntervalSince1970: 1_700_000_060)
        let coordinator = try makeCoordinator(now: first, isBundledAvailable: true)

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x"))
        coordinator.nowProvider = { second }
        coordinator.handleProgressEvent(.uploadSucceeded(segment: "y"))

        #expect(coordinator.bundledJournalLastIngestAt == second)
    }

    @Test func recentErrorCountIncrementsClampsAndResetsOnJournalContact() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: false)

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
            now: Date(timeIntervalSince1970: 1_700_000_000),
            isBundledAvailable: false
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
            now: Date(timeIntervalSince1970: 1_700_000_000),
            isBundledAvailable: false
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

    @Test func observerHealthPayloadDoesNotLeakRawFailureDetails() throws {
        let coordinator = try makeCoordinator(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            isBundledAvailable: false
        )
        coordinator.handleProgressEvent(.uploadFailed(
            segment: "143022_300",
            error: "/tmp/private/143022_300/file.mp4?token=secret",
            healthReason: .uploadFailed
        ))

        let health = ObserverHealthSnapshot(
            name: nil,
            streamType: "desktop",
            version: "1.2.3",
            uptimeSeconds: 5,
            lastSuccessfulSync: coordinator.lastSyncedAt,
            pendingQueueDepth: coordinator.pendingCount,
            recentErrorCount: coordinator.recentErrorCount,
            lastErrorReason: coordinator.lastErrorReason
        )
        let request = try UploadClient().buildObserverStatusRequest(
            serverURL: "http://example.com",
            serverKey: "secret",
            paused: false,
            health: health
        )
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let serialized = String(data: body, encoding: .utf8) ?? ""

        #expect(Set(payload.keys) == [
            "tract",
            "event",
            "paused",
            "source",
            "stream_type",
            "version",
            "uptime",
            "pending_queue_depth",
            "recent_error_count",
            "last_error_reason"
        ])
        #expect(payload["last_error_reason"] as? String == "upload_failed")
        #expect(!serialized.contains("143022_300"))
        #expect(!serialized.contains("/tmp/private"))
        #expect(!serialized.contains("token"))
        #expect(!serialized.contains("secret"))
    }

    @Test func syncOnStartupWaitsForInitialConfigurationBeforeSyncing() async throws {
        resetSyncedDaysCache()
        store.reset()
        let root = try makeTempDirectory("upload-coordinator-startup")
        let segment = try makeSegment(root: root)
        let sha = try #require(UploadClient().sha256(
            of: segment.url.appendingPathComponent("\(segment.url.lastPathComponent)_audio.m4a")
        ))
        store.enqueue(
            statusCode: 200,
            body: listingJSON(
                key: segment.url.lastPathComponent,
                submittedName: "\(segment.url.lastPathComponent)_audio.m4a",
                sha: sha
            )
        )
        let coordinator = UploadCoordinator(
            storageManager: StorageManager(baseDirectory: root),
            config: AppConfig(serverURL: "https://configured.example", serverKey: "secret"),
            client: UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store)),
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24692") }
        )

        let syncTask = Task {
            await coordinator.syncOnStartup()
        }
        await store.waitForRequestCount(1)
        await syncTask.value

        let request = try #require(store.snapshotRequests().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/app/observer/ingest/segments/\(dayString(for: segment.date))")
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

    private func listingJSON(key: String, submittedName: String, sha: String) -> String {
        #"[{"key":"\#(key)","files":[{"name":"audio.m4a","size":5,"submitted_name":"\#(submittedName)","sha256":"\#(sha)","status":"present"}]}]"#
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

    private func makeCoordinator(now: Date, isBundledAvailable: Bool) throws -> UploadCoordinator {
        let root = try makeTempDirectory("upload-coordinator")
        let coordinator = UploadCoordinator(
            forSnapshot: StorageManager(baseDirectory: root),
            config: AppConfig()
        )
        coordinator.nowProvider = { now }
        coordinator.bundledAvailabilityProvider = { isBundledAvailable }
        return coordinator
    }
}
