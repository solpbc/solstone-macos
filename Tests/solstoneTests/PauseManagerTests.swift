// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing
@testable import solstone

@MainActor
final class FakePauseExpiryScheduler {
    private var onExpire: (@MainActor @Sendable () -> Void)?
    private(set) var retained: [@MainActor @Sendable () -> Void] = []
    private(set) var armedIntervals: [TimeInterval] = []

    var scheduler: PauseExpiryScheduler {
        { [weak self] interval, onExpire in
            self?.armedIntervals.append(interval)
            self?.onExpire = onExpire
            self?.retained.append(onExpire)
            return FakePauseExpiryTimer { [weak self] in self?.onExpire = nil }
        }
    }

    /// Deterministically fire the armed expiry.
    func fire() { onExpire?() }
}

final class FakePauseExpiryTimer: PauseExpiryTimer {
    private let onInvalidate: () -> Void
    init(onInvalidate: @escaping () -> Void) { self.onInvalidate = onInvalidate }
    func invalidate() { onInvalidate() }
}

@Suite("PauseManager")
@MainActor
struct PauseManagerTests {
    @Test func replacedExpiryCannotEndIndefiniteOwnerPause() async throws {
        let suite = "pause-replacement-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = FakePauseExpiryScheduler()
        let manager = PauseManager(defaults: defaults, expiryScheduler: scheduler.scheduler)
        var resumes = 0
        manager.onResume = { _ in resumes += 1 }
        manager.pause(for: .seconds(60))
        manager.pause(for: .indefinite)
        scheduler.retained[0]()
        await Task.yield()
        #expect(manager.isPaused && manager.pauseState.isIndefinite)
        #expect(defaults.string(forKey: "ownerPause") == "indefinite")
        #expect(resumes == 0)
    }

    @Test func replacedDeadlineRejectsQueuedOldExpiryButCurrentDeadlineResumes() async throws {
        let scheduler = FakePauseExpiryScheduler()
        let manager = PauseManager(expiryScheduler: scheduler.scheduler)
        var causes: [PauseManager.ResumeCause] = []
        manager.onResume = { causes.append($0) }
        manager.pause(for: .seconds(60))
        manager.pause(for: .seconds(120))
        let deadline = manager.pauseState.expirationDate
        scheduler.retained[0]()
        await Task.yield()
        #expect(manager.isPaused && manager.pauseState.expirationDate == deadline)
        #expect(causes.isEmpty)
        scheduler.retained[1]()
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { causes.count == 1 } }
        #expect(!manager.isPaused && causes == [.deadline])
    }

    @Test func newPauseFencesAlreadyQueuedResumeDelivery() async throws {
        let manager = PauseManager()
        var resumes = 0
        manager.onResume = { _ in resumes += 1 }
        manager.pause(for: .indefinite)
        manager.resume()
        manager.pause(for: .indefinite)
        await Task.yield()
        #expect(manager.isPaused && resumes == 0)
    }
    @Test func pauseForMinutesSetsExpiration() {
        let manager = PauseManager()
        let before = Date()
        manager.pause(for: .minutes(15))
        let after = Date()

        #expect(manager.isPaused)
        #expect(manager.pauseState.expirationDate != nil)

        let expiration = manager.pauseState.expirationDate!
        #expect(expiration.timeIntervalSince(before) >= 15 * 60 - 1)
        #expect(expiration.timeIntervalSince(after) <= 15 * 60 + 1)
    }

    @Test func pauseIndefinitelyHasNoExpiration() {
        let manager = PauseManager()
        manager.pause(for: .indefinite)

        #expect(manager.isPaused)
        #expect(manager.pauseState.expirationDate == nil)
        #expect(manager.pauseState.isIndefinite)
    }

    @Test func resumeClearsPauseState() {
        let manager = PauseManager()
        manager.pause(for: .minutes(30))
        #expect(manager.isPaused)

        manager.resume()
        #expect(!manager.isPaused)
        #expect(manager.pauseState.expirationDate == nil)
    }

    @Test func timedPauseAutoResumesAtExpiry() async throws {
        let scheduler = FakePauseExpiryScheduler()
        let manager = PauseManager(expiryScheduler: scheduler.scheduler)
        let pauseCallbackCount = LockedCounter()
        let resumeCallbackCount = LockedCounter()
        manager.onPause = {
            pauseCallbackCount.increment()
        }
        manager.onResume = { _ in
            resumeCallbackCount.increment()
        }

        manager.pause(for: .seconds(1))
        await Task.yield()
        scheduler.fire()

        try await withTimeout(seconds: 3) {
            await resumeCallbackCount.waitUntilCount(1)
        }
        #expect(!manager.isPaused)
        #expect(pauseCallbackCount.count == 1)
    }

    @Test func indefinitePauseDoesNotAutoResume() async throws {
        let manager = PauseManager()
        let resumeCallbackCount = LockedCounter()
        manager.onResume = { _ in
            resumeCallbackCount.increment()
        }

        manager.pause(for: .indefinite)
        try await Task.sleep(for: .milliseconds(250))

        #expect(manager.isPaused)
        #expect(resumeCallbackCount.count == 0)
    }

    @Test func formatTimeRemainingShowsMinutes() {
        let manager = PauseManager()
        manager.pause(for: .minutes(15))

        let text = manager.formatTimeRemaining()
        #expect(text != nil)
        #expect(text!.contains("min"))
    }

    @Test func formatTimeRemainingNilWhenIndefinite() {
        let manager = PauseManager()
        manager.pause(for: .indefinite)

        #expect(manager.formatTimeRemaining() == nil)
    }

    @Test func formatTimeRemainingNilWhenNotPaused() {
        let manager = PauseManager()
        #expect(manager.formatTimeRemaining() == nil)
    }

    @Test func durationExpirationDates() {
        let before = Date()
        let fiveMin = PauseManager.PauseDuration.minutes(5).expirationDate(at: before)
        let twoHour = PauseManager.PauseDuration.minutes(120).expirationDate(at: before)
        let indefinite = PauseManager.PauseDuration.indefinite.expirationDate(at: before)

        #expect(fiveMin != nil)
        #expect(fiveMin!.timeIntervalSince(before) >= 5 * 60 - 1)
        #expect(fiveMin!.timeIntervalSince(before) <= 5 * 60 + 1)

        #expect(twoHour != nil)
        #expect(twoHour!.timeIntervalSince(before) >= 120 * 60 - 1)
        #expect(twoHour!.timeIntervalSince(before) <= 120 * 60 + 1)

        #expect(indefinite == nil)
    }

    @Test func indefinitePauseRoundTripsAcrossManagers() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }

        PauseManager(defaults: isolated.defaults).pause(for: .indefinite)

        let restored = PauseManager(defaults: isolated.defaults)
        #expect(restored.isPaused)
        #expect(restored.pauseState.isIndefinite)
    }

    @Test func missingOwnerPauseKeyRestoresUnpaused() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }

        let restored = PauseManager(defaults: isolated.defaults)

        #expect(!restored.isPaused)
        #expect(isolated.defaults.object(forKey: "ownerPause") == nil)
    }

    @Test func injectedStoreRemovesOnlyTheSixObsoletePauseKeys() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let obsoleteKeys = [
            "audioMuteExpiration", "audioMuteIndefinite", "videoMuteExpiration",
            "videoMuteIndefinite", "pauseExpiration", "pauseIndefinite"
        ]
        for key in obsoleteKeys {
            isolated.defaults.set("obsolete", forKey: key)
        }
        isolated.defaults.set("indefinite", forKey: "ownerPause")

        let restored = PauseManager(defaults: isolated.defaults)

        #expect(restored.isPaused)
        #expect(obsoleteKeys.allSatisfy { isolated.defaults.object(forKey: $0) == nil })
        #expect(isolated.defaults.string(forKey: "ownerPause") == "indefinite")
    }

    @Test func timedPauseRestoresWithRemainingDeadlineAndExpires() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let originalScheduler = FakePauseExpiryScheduler()
        let original = PauseManager(defaults: isolated.defaults, expiryScheduler: originalScheduler.scheduler, now: { t0 })
        original.pause(for: .minutes(15))

        let restoredScheduler = FakePauseExpiryScheduler()
        let restored = PauseManager(
            defaults: isolated.defaults,
            expiryScheduler: restoredScheduler.scheduler,
            now: { t0.addingTimeInterval(5 * 60) }
        )

        #expect(restored.isPaused)
        #expect(restored.pauseState.expirationDate == t0.addingTimeInterval(15 * 60))
        #expect(restoredScheduler.armedIntervals.count == 1)
        #expect(abs(restoredScheduler.armedIntervals[0] - 600) <= 1)
        #expect(restored.formatTimeRemaining() == "10 mins")

        restoredScheduler.fire()
        #expect(!restored.isPaused)
        #expect(isolated.defaults.object(forKey: "ownerPause") == nil)
        #expect(!PauseManager(defaults: isolated.defaults, now: { t0.addingTimeInterval(5 * 60) }).isPaused)
    }

    @Test func expiredTimedPauseIsRemovedWithoutArmingExpiry() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let original = PauseManager(defaults: isolated.defaults, now: { t0 })
        original.pause(for: .minutes(15))

        let scheduler = FakePauseExpiryScheduler()
        let restored = PauseManager(
            defaults: isolated.defaults,
            expiryScheduler: scheduler.scheduler,
            now: { t0.addingTimeInterval(20 * 60) }
        )

        #expect(!restored.isPaused)
        #expect(isolated.defaults.object(forKey: "ownerPause") == nil)
        #expect(scheduler.armedIntervals.isEmpty)
    }

    @Test func resumeRemovesPersistedPause() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let manager = PauseManager(defaults: isolated.defaults)
        manager.pause(for: .indefinite)

        manager.resume()

        #expect(isolated.defaults.object(forKey: "ownerPause") == nil)
        #expect(!PauseManager(defaults: isolated.defaults).isPaused)
    }

    @Test func malformedValuesRestoreIndefiniteAndRemainUntilResume() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let values: [(Any, String)] = [
            (true, "bool"),
            (["reason": "test"], "dictionary"),
            (["test"], "array"),
            ("not-indefinite", "string")
        ]

        for (value, kind) in values {
            isolated.defaults.set(value, forKey: "ownerPause")
            let manager = PauseManager(defaults: isolated.defaults)
            #expect(manager.isPaused, "\(kind) restores paused")
            #expect(manager.pauseState.isIndefinite, "\(kind) restores indefinite")
            switch kind {
            case "bool":
                let number = isolated.defaults.object(forKey: "ownerPause") as? NSNumber
                #expect(number.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true)
            case "dictionary":
                #expect(isolated.defaults.dictionary(forKey: "ownerPause")?["reason"] as? String == "test")
            case "array":
                #expect(isolated.defaults.stringArray(forKey: "ownerPause") == ["test"])
            default:
                #expect(isolated.defaults.string(forKey: "ownerPause") == "not-indefinite")
            }

            manager.resume()
            #expect(isolated.defaults.object(forKey: "ownerPause") == nil)
            #expect(!PauseManager(defaults: isolated.defaults).isPaused)
        }
    }

    @Test func nonFiniteNumbersRestoreIndefiniteAndRemainUntilResume() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }

        for value in [Double.nan, Double.infinity, -Double.infinity] {
            isolated.defaults.set(value, forKey: "ownerPause")
            let manager = PauseManager(defaults: isolated.defaults)
            #expect(manager.isPaused)
            #expect(manager.pauseState.isIndefinite)
            #expect(isolated.defaults.object(forKey: "ownerPause") != nil)
            manager.resume()
            #expect(isolated.defaults.object(forKey: "ownerPause") == nil)
        }
    }

    @Test func storelessPauseDoesNotReadOrWriteStandardDefaults() {
        let legacyKeys = [
            "ownerPause", "audioMuteExpiration", "audioMuteIndefinite",
            "videoMuteExpiration", "videoMuteIndefinite", "pauseExpiration", "pauseIndefinite"
        ]
        let standardDefaults = UserDefaults.standard
        let before = standardDefaults.dictionaryRepresentation().filter { legacyKeys.contains($0.key) }

        PauseManager().pause(for: .indefinite)
        let fresh = PauseManager()

        let after = standardDefaults.dictionaryRepresentation().filter { legacyKeys.contains($0.key) }
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
        #expect(!fresh.isPaused)
    }

    @Test func farFutureDeadlineIsRestoredWithoutClamping() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(10 * 365 * 24 * 60 * 60)
        isolated.defaults.set(deadline.timeIntervalSince1970, forKey: "ownerPause")
        let scheduler = FakePauseExpiryScheduler()

        let restored = PauseManager(defaults: isolated.defaults, expiryScheduler: scheduler.scheduler, now: { now })

        #expect(restored.isPaused)
        #expect(restored.pauseState.expirationDate == deadline)
        #expect(scheduler.armedIntervals.count == 1)
        #expect(abs(scheduler.armedIntervals[0] - deadline.timeIntervalSince(now)) <= 1)
    }
}
