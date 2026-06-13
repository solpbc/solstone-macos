// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("UploadCoordinator")
@MainActor
struct UploadCoordinatorTests {
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

    @Test func externalSyncCompleteStillUpdatesLastSyncedAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: false)

        coordinator.handleProgressEvent(.syncComplete)

        #expect(coordinator.bundledJournalLastIngestAt == nil)
        #expect(coordinator.lastSyncedAt != nil)
    }

    @Test func uploadFailedDoesNotSetBundledLastIngestAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: true)

        coordinator.handleProgressEvent(.uploadFailed(segment: "x", error: "offline"))

        #expect(coordinator.bundledJournalLastIngestAt == nil)
    }

    @Test func uploadFailedAfterSuccessDoesNotClearLastIngestAt() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = try makeCoordinator(now: fixed, isBundledAvailable: true)

        coordinator.handleProgressEvent(.uploadSucceeded(segment: "x"))
        coordinator.handleProgressEvent(.uploadFailed(segment: "x", error: "offline"))

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
