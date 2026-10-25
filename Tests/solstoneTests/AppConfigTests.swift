// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("AppConfig")
struct AppConfigTests {
    private func makeDevice(
        id: AudioDeviceID = 1,
        name: String = "Test Mic",
        uid: String = "test-uid",
        transportType: AudioTransportType = .usb
    ) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            name: name,
            uid: uid,
            manufacturer: nil,
            sampleRate: 48000,
            transportType: transportType
        )
    }

    // MARK: - selectBestMicrophone

    @Test func selectBestMicrophoneRespectsPriorityOrder() {
        let config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "uid-a", name: "Mic A"),
            MicrophoneEntry(uid: "uid-b", name: "Mic B")
        ])
        let available = [
            makeDevice(id: 2, name: "Mic B", uid: "uid-b"),
            makeDevice(id: 1, name: "Mic A", uid: "uid-a")
        ]
        let best = config.selectBestMicrophone(from: available)
        #expect(best?.uid == "uid-a")
    }

    @Test func selectBestMicrophoneReturnsNilWhenNoMatch() {
        let config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "uid-a", name: "Mic A")
        ])
        let available = [makeDevice(uid: "uid-other")]
        #expect(config.selectBestMicrophone(from: available) == nil)
    }

    @Test func selectBestMicrophoneReturnsNilWhenEmpty() {
        let config = AppConfig()
        let best = config.selectBestMicrophone(from: [makeDevice()])
        #expect(best == nil)
    }

    // MARK: - disabledMicrophoneUIDs

    @Test func disabledMicrophoneUIDsFiltersCorrectly() {
        let config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "uid-a", name: "Mic A", isDisabled: false),
            MicrophoneEntry(uid: "uid-b", name: "Mic B", isDisabled: true),
            MicrophoneEntry(uid: "uid-c", name: "Mic C", isDisabled: true)
        ])
        #expect(config.disabledMicrophoneUIDs == Set(["uid-b", "uid-c"]))
    }

    @Test func disabledMicrophoneUIDsEmptyWhenNoneDisabled() {
        let config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "uid-a", name: "Mic A")
        ])
        #expect(config.disabledMicrophoneUIDs.isEmpty)
    }

    @Test func enabledMicrophoneUIDsFiltersCorrectly() {
        let config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "uid-a", name: "Mic A", isDisabled: false),
            MicrophoneEntry(uid: "uid-b", name: "Mic B", isDisabled: true),
            MicrophoneEntry(uid: "uid-c", name: "Mic C", isDisabled: false)
        ])
        #expect(config.enabledMicrophoneUIDs == Set(["uid-a", "uid-c"]))
    }

    // MARK: - addMicrophone

    @Test func addMicrophoneReturnsTrueForNew() {
        var config = AppConfig()
        let added = config.addMicrophone(makeDevice(uid: "uid-new"))
        #expect(added == true)
        #expect(config.microphonePriority.count == 1)
        #expect(config.microphonePriority[0].uid == "uid-new")
    }

    @Test func addMicrophoneReturnsFalseForDuplicate() {
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "uid-a", name: "Mic A")
        ])
        let added = config.addMicrophone(makeDevice(uid: "uid-a"))
        #expect(added == false)
        #expect(config.microphonePriority.count == 1)
    }

    @Test func addMicrophoneDefaultsOptInOnlyDevicesDisabled() {
        var config = AppConfig()
        let added = config.addMicrophone(makeDevice(uid: "uid-continuity", transportType: .continuityWireless))

        #expect(added)
        #expect(config.microphonePriority[0].isDisabled)
    }

    @Test func addMicrophoneDefaultsNonOptInDevicesEnabled() {
        var config = AppConfig()
        let added = config.addMicrophone(makeDevice(uid: "uid-usb", transportType: .usb))

        #expect(added)
        #expect(!config.microphonePriority[0].isDisabled)
    }

    // MARK: - removeMicrophone

    @Test func removeMicrophoneReturnsTrueWhenFound() {
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "uid-a", name: "Mic A")
        ])
        #expect(config.removeMicrophone(uid: "uid-a") == true)
        #expect(config.microphonePriority.isEmpty)
    }

    @Test func removeMicrophoneReturnsFalseWhenNotFound() {
        var config = AppConfig()
        #expect(config.removeMicrophone(uid: "uid-missing") == false)
    }

    // MARK: - isUploadConfigured

    @Test func isUploadConfiguredTrueWhenBothSet() {
        let config = AppConfig(serverURL: "https://example.com", serverKey: "secret-key")
        #expect(config.isUploadConfigured == true)
    }

    @Test func isUploadConfiguredFalseWhenNoURL() {
        let config = AppConfig(serverKey: "secret-key")
        #expect(config.isUploadConfigured == false)
    }

    @Test func isUploadConfiguredFalseWhenNoKey() {
        let config = AppConfig(serverURL: "https://example.com")
        #expect(config.isUploadConfigured == false)
    }

    @Test func isUploadConfiguredFalseWhenEmptyURL() {
        let config = AppConfig(serverURL: "", serverKey: "secret-key")
        #expect(config.isUploadConfigured == false)
    }

    @Test func isUploadConfiguredFalseWhenEmptyKey() {
        let config = AppConfig(serverURL: "https://example.com", serverKey: "")
        #expect(config.isUploadConfigured == false)
    }

    // MARK: - excludeApp / includeApp

    @Test func excludeAppReturnsTrueForNew() {
        var config = AppConfig()
        #expect(config.excludeApp(bundleID: "com.test.app", name: "Test") == true)
        #expect(config.excludedApps.count == 1)
    }

    @Test func excludeAppReturnsFalseForDuplicate() {
        var config = AppConfig(excludedApps: [
            AppEntry(bundleID: "com.test.app", name: "Test")
        ])
        #expect(config.excludeApp(bundleID: "com.test.app", name: "Test") == false)
    }

    @Test func includeAppReturnsTrueWhenFound() {
        var config = AppConfig(excludedApps: [
            AppEntry(bundleID: "com.test.app", name: "Test")
        ])
        #expect(config.includeApp(bundleID: "com.test.app") == true)
        #expect(config.excludedApps.isEmpty)
    }

    @Test func includeAppReturnsFalseWhenNotFound() {
        var config = AppConfig()
        #expect(config.includeApp(bundleID: "com.missing.app") == false)
    }

    // MARK: - toggleMicrophoneDisabled

    @Test func toggleMicrophoneDisabledFlipsState() {
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "uid-a", name: "Mic A", isDisabled: false)
        ])
        config.toggleMicrophoneDisabled(uid: "uid-a")
        #expect(config.microphonePriority[0].isDisabled == true)
        config.toggleMicrophoneDisabled(uid: "uid-a")
        #expect(config.microphonePriority[0].isDisabled == false)
    }

    @Test func toggleMicrophoneDisabledIgnoresMissing() {
        var config = AppConfig()
        config.toggleMicrophoneDisabled(uid: "uid-missing")
        #expect(config.microphonePriority.isEmpty)
    }

    // MARK: - Capture Sources

    @Test func captureSourcesDefaultToEnabled() {
        let config = AppConfig()
        #expect(config.isScreenCaptureEnabled)
        #expect(config.isMicrophoneCaptureEnabled)
        #expect(config.selectedSources == [.screen, .microphone])
    }

    @Test func captureSourcesReflectExplicitConfiguration() {
        var config = AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: false)
        #expect(config.isScreenCaptureEnabled)
        #expect(!config.isMicrophoneCaptureEnabled)
        #expect(config.selectedSources == [.screen])

        config.isMicrophoneCaptureEnabled = true
        #expect(config.selectedSources == [.screen, .microphone])

        config.isScreenCaptureEnabled = false
        #expect(config.selectedSources == [.microphone])
    }

    // MARK: - Protected Video Settings

    @Test func protectedVideoSettingsDefaultWhenKeysMissing() throws {
        let suiteName = "test.appconfig.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = AppConfig.load(from: defaults)
        #expect(config.pauseForProtectedVideo == true)
        #expect(config.protectedVideoTitlePatterns.isEmpty)
    }

    @Test func protectedVideoSettingsRoundTripPatterns() throws {
        let suiteName = "test.appconfig.roundtrip.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = AppConfig(
            pauseForProtectedVideo: false,
            protectedVideoTitlePatterns: ["custom-service", "another-stream"]
        )
        try config.save(to: defaults)

        let loaded = AppConfig.load(from: defaults)
        #expect(loaded.pauseForProtectedVideo == false)
        #expect(loaded.protectedVideoTitlePatterns == ["custom-service", "another-stream"])
    }

    @Test func addProtectedVideoTitlePatternRejectsBlankAndDoesNotStore() {
        var config = AppConfig()
        let result = config.addProtectedVideoTitlePattern("  ")
        #expect(result == false)
        #expect(config.protectedVideoTitlePatterns.isEmpty)
    }

    @Test func storedBlankPatternIsDroppedOnLoad() throws {
        let suiteName = "test.appconfig.blank.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["valid-pattern", "   ", "\t\n", "another-pattern"], forKey: "protectedVideoTitlePatterns")
        defaults.set(true, forKey: "pauseForProtectedVideo")

        let config = AppConfig.load(from: defaults)
        #expect(config.protectedVideoTitlePatterns == ["valid-pattern", "another-pattern"])
    }

    // MARK: - Sparse Scalar Persistence

    @Test func untouchedSaveOmitsOwnerScalarDefaults() throws {
        let suiteName = "test.appconfig.sparse.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = AppConfig()
        try config.save(to: defaults)

        let convertedKeys = [
            "isBrowserIntakeEnabled",
            "excludePrivateBrowsing",
            "excludePrivateBrowsingAccessibility",
            "activityAccessibilityEnabled",
            "syncPaused",
            "debugSegments",
            "preserveSyncedSegments",
            "microphoneGain",
            "silenceMusic",
            "pauseForProtectedVideo",
        ]
        for key in convertedKeys {
            #expect(defaults.object(forKey: key) == nil, "Expected \(key) to be omitted from defaults")
        }

        #expect(defaults.object(forKey: "isScreenCaptureEnabled") as? Bool == true)
        #expect(defaults.object(forKey: "isMicrophoneCaptureEnabled") as? Bool == true)
    }

    @Test func explicitChoiceEqualToDefaultPersists() throws {
        let suiteName = "test.appconfig.explicit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var config = AppConfig()
        config.excludePrivateBrowsing = true
        config.microphoneGain = 2.0
        try config.save(to: defaults)

        let loaded = AppConfig.load(from: defaults)
        #expect(defaults.object(forKey: "excludePrivateBrowsing") as? Bool == true)
        #expect(defaults.object(forKey: "microphoneGain") as? Float == 2.0)

        var updated = loaded
        updated.serverURL = "https://journal.example.test"
        try updated.save(to: defaults)

        #expect(defaults.object(forKey: "excludePrivateBrowsing") as? Bool == true)
        #expect(defaults.object(forKey: "microphoneGain") as? Float == 2.0)
        #expect(defaults.object(forKey: "syncPaused") == nil)
        #expect(updated.syncPaused == false)
        #expect(updated.isBrowserIntakeEnabled == true)
    }

    @Test func freshNativeSetupAndUnqualifiedSetupOnSuite() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let absent = dir.appendingPathComponent("absent.json")
        let contDir = dir.appendingPathComponent("continuation", isDirectory: true)

        let suiteName = "test.appconfig.fresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let freshConfig = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: contDir,
            nativeSetupEnabled: true,
            defaults: defaults
        )

        #expect(!freshConfig.isScreenCaptureEnabled)
        #expect(!freshConfig.isMicrophoneCaptureEnabled)
        let store = SetupContinuationStore(directory: contDir)
        #expect(try store.loadChecked()?.phase == .journal)
        #expect(defaults.bool(forKey: "didRecordConfigPresence"))
        #expect(defaults.bool(forKey: "didReseedCaptureSourcesOn"))
        #expect(defaults.bool(forKey: "didAddPasswordManagerExclusions"))
        #expect(defaults.bool(forKey: "didFinishOwnerScalarConversion"))
        #expect(freshConfig.excludedApps == AppConfig.defaultExclusions)

        let convertedKeys = [
            "isBrowserIntakeEnabled", "excludePrivateBrowsing", "excludePrivateBrowsingAccessibility",
            "activityAccessibilityEnabled", "syncPaused", "debugSegments",
            "preserveSyncedSegments", "microphoneGain", "silenceMusic", "pauseForProtectedVideo"
        ]
        for key in convertedKeys {
            #expect(defaults.object(forKey: key) == nil)
        }

        let beforeContinuation = try Data(contentsOf: store.fileURL)
        let secondConfig = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: contDir,
            nativeSetupEnabled: true,
            defaults: defaults
        )
        #expect(!secondConfig.isScreenCaptureEnabled)
        #expect(!secondConfig.isMicrophoneCaptureEnabled)
        #expect(try Data(contentsOf: store.fileURL) == beforeContinuation)

        // Unqualified fresh setup
        let unqSuite = "test.appconfig.unqualified.\(UUID().uuidString)"
        let unqDefaults = try #require(UserDefaults(suiteName: unqSuite))
        defer { unqDefaults.removePersistentDomain(forName: unqSuite) }
        let unqContDir = dir.appendingPathComponent("unqCont", isDirectory: true)

        let unqConfig = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: unqContDir,
            nativeSetupEnabled: false,
            defaults: unqDefaults
        )
        #expect(unqConfig.isScreenCaptureEnabled)
        #expect(unqConfig.isMicrophoneCaptureEnabled)
        #expect(!FileManager.default.fileExists(atPath: SetupContinuationStore(directory: unqContDir).fileURL.path))
        #expect(unqDefaults.bool(forKey: "didRecordConfigPresence"))

        // Thrown continuation write leaves existence, completion, reseeds, and converted keys absent
        let blockedSuite = "test.appconfig.blocked.\(UUID().uuidString)"
        let blockedDefaults = try #require(UserDefaults(suiteName: blockedSuite))
        defer { blockedDefaults.removePersistentDomain(forName: blockedSuite) }
        let blockedDir = dir.appendingPathComponent("blockedCont", isDirectory: true)
        let blockedStore = SetupContinuationStore(directory: blockedDir, replace: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })

        #expect(throws: CocoaError.self) {
            try AppConfig.loadOrCreateDefault(
                legacyConfigPaths: [absent],
                continuationDirectory: blockedDir,
                nativeSetupEnabled: true,
                continuationStore: blockedStore,
                defaults: blockedDefaults
            )
        }
        #expect(blockedDefaults.object(forKey: "didRecordConfigPresence") == nil)
        #expect(blockedDefaults.object(forKey: "didFinishOwnerScalarConversion") == nil)
        #expect(blockedDefaults.object(forKey: "didReseedCaptureSourcesOn") == nil)
        for key in convertedKeys {
            #expect(blockedDefaults.object(forKey: key) == nil)
        }

        let retry = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: blockedDir,
            nativeSetupEnabled: true,
            continuationStore: SetupContinuationStore(directory: blockedDir),
            defaults: blockedDefaults
        )
        #expect(!retry.isScreenCaptureEnabled)
        #expect(!retry.isMicrophoneCaptureEnabled)
        #expect(blockedDefaults.bool(forKey: "didRecordConfigPresence"))
    }

    @Test func preConversionDomainStripsFrozenDefaultsOnce() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let absent = dir.appendingPathComponent("absent.json")
        let contDir = dir.appendingPathComponent("continuation", isDirectory: true)

        let suiteName = "test.appconfig.preconversion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "isBrowserIntakeEnabled")
        defaults.set(true, forKey: "excludePrivateBrowsing")
        defaults.set(false, forKey: "excludePrivateBrowsingAccessibility")
        defaults.set(false, forKey: "activityAccessibilityEnabled")
        defaults.set(false, forKey: "syncPaused")
        defaults.set(false, forKey: "debugSegments")
        defaults.set(false, forKey: "preserveSyncedSegments")
        defaults.set(Float(2.0), forKey: "microphoneGain")
        defaults.set(true, forKey: "silenceMusic")
        defaults.set(true, forKey: "pauseForProtectedVideo")

        defaults.set(false, forKey: "isScreenCaptureEnabled")
        defaults.set(true, forKey: "isMicrophoneCaptureEnabled")
        defaults.set(try JSONEncoder().encode([MicrophoneEntry(uid: "mic-1", name: "Mic 1")]), forKey: "microphonePriority")
        defaults.set(try JSONEncoder().encode([AppEntry(bundleID: "com.test.app", name: "Test App")]), forKey: "excludedApps")
        defaults.set(["fixture-pattern"], forKey: "excludedTitlePatterns")
        defaults.set(["protected-pattern"], forKey: "protectedVideoTitlePatterns")

        let loaded = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: contDir,
            defaults: defaults
        )

        let convertedKeys = [
            "isBrowserIntakeEnabled", "excludePrivateBrowsing", "excludePrivateBrowsingAccessibility",
            "activityAccessibilityEnabled", "syncPaused", "debugSegments",
            "preserveSyncedSegments", "microphoneGain", "silenceMusic", "pauseForProtectedVideo"
        ]
        for key in convertedKeys {
            #expect(defaults.object(forKey: key) == nil, "Expected \(key) to be removed during conversion")
        }
        #expect(defaults.bool(forKey: "didRecordConfigPresence"))
        #expect(defaults.bool(forKey: "didFinishOwnerScalarConversion"))
        #expect(!loaded.isScreenCaptureEnabled)
        #expect(loaded.isMicrophoneCaptureEnabled)
        #expect(loaded.microphonePriority.count == 1)
        #expect(loaded.excludedApps.count == 1)
        #expect(loaded.excludedTitlePatterns == ["fixture-pattern"])
        #expect(loaded.protectedVideoTitlePatterns == ["protected-pattern"])

        var updated = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: contDir,
            defaults: defaults
        )
        updated.serverURL = "https://example.com"
        try updated.save(to: defaults)
        for key in convertedKeys {
            #expect(defaults.object(forKey: key) == nil)
        }

        // Domain with only existence marker plus source keys stays existing and does not write continuation
        let existSuite = "test.appconfig.existonly.\(UUID().uuidString)"
        let existDefaults = try #require(UserDefaults(suiteName: existSuite))
        defer { existDefaults.removePersistentDomain(forName: existSuite) }
        let existContDir = dir.appendingPathComponent("existCont", isDirectory: true)

        existDefaults.set(true, forKey: "didRecordConfigPresence")
        existDefaults.set(true, forKey: "didFinishOwnerScalarConversion")
        existDefaults.set(true, forKey: "isScreenCaptureEnabled")
        existDefaults.set(true, forKey: "isMicrophoneCaptureEnabled")

        _ = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: existContDir,
            nativeSetupEnabled: true,
            defaults: existDefaults
        )
        #expect(!FileManager.default.fileExists(atPath: SetupContinuationStore(directory: existContDir).fileURL.path))
    }

    @Test func mixedDomainKeepsNondefaultsAndUnreadable() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let absent = dir.appendingPathComponent("absent.json")
        let contDir = dir.appendingPathComponent("continuation", isDirectory: true)

        let suiteName = "test.appconfig.mixed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "excludePrivateBrowsing") // sentinel
        defaults.set(true, forKey: "silenceMusic") // eligible default -> strip
        defaults.set(true, forKey: "syncPaused") // nondefault -> keep
        defaults.set("nope", forKey: "microphoneGain") // unreadable -> keep
        defaults.set(true, forKey: "didAdoptActivityFollowsScreen")
        defaults.set(true, forKey: "didReseedCaptureSourcesOn")
        defaults.set(false, forKey: "activityTitlesEnabled") // owner choice

        let config = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: contDir,
            defaults: defaults
        )

        #expect(defaults.object(forKey: "silenceMusic") == nil)
        #expect(defaults.object(forKey: "syncPaused") as? Bool == true)
        #expect(defaults.object(forKey: "microphoneGain") as? String == "nope")
        #expect(defaults.bool(forKey: "didAdoptActivityFollowsScreen"))
        #expect(defaults.bool(forKey: "didReseedCaptureSourcesOn"))
        #expect(defaults.object(forKey: "activityTitlesEnabled") as? Bool == false)
        #expect(config.activityTitlesEnabled == false)

        _ = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: contDir,
            defaults: defaults
        )
        #expect(defaults.object(forKey: "syncPaused") as? Bool == true)
        #expect(defaults.object(forKey: "microphoneGain") as? String == "nope")
        #expect(defaults.object(forKey: "activityTitlesEnabled") as? Bool == false)
    }

    @Test func externalDefaultChoicesAndRemovalsReconcileWithoutSaveLoops() throws {
        let suite = "test.appconfig.external-choices.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let choices: [(String, Any)] = [
            ("isBrowserIntakeEnabled", true), ("excludePrivateBrowsing", true),
            ("excludePrivateBrowsingAccessibility", false), ("activityAccessibilityEnabled", false),
            ("syncPaused", false), ("debugSegments", false), ("preserveSyncedSegments", false),
            ("microphoneGain", Float(2.0)), ("silenceMusic", true), ("pauseForProtectedVideo", true)
        ]
        for (key, value) in choices {
            defaults.removePersistentDomain(forName: suite)
            var current = AppConfig.load(from: defaults)
            defaults.set(value, forKey: key)
            let fresh = AppConfig.load(from: defaults)
            #expect(fresh != current, "External choice for \(key) must trigger reconciliation")
            current = fresh
            current.serverURL = "https://journal.test"
            try current.save(to: defaults)
            #expect(defaults.object(forKey: key) != nil)
            #expect(AppConfig.load(from: defaults) == current)

            defaults.removeObject(forKey: key)
            let cleared = AppConfig.load(from: defaults)
            #expect(cleared != current, "Removing \(key) must restore code-default behavior")
            current = cleared
            current.serverKey = "test-key"
            try current.save(to: defaults)
            #expect(defaults.object(forKey: key) == nil)
            #expect(AppConfig.load(from: defaults) == current)
        }
    }

    @Test func existingStringBooleansKeepTheirMeaningThroughConversionAndSave() throws {
        let suite = "test.appconfig.coerced-bools.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fields: [(String, KeyPath<AppConfig, Bool>)] = [
            ("excludePrivateBrowsingAccessibility", \.excludePrivateBrowsingAccessibility),
            ("activityAccessibilityEnabled", \.activityAccessibilityEnabled),
            ("syncPaused", \.syncPaused), ("debugSegments", \.debugSegments),
            ("preserveSyncedSegments", \.preserveSyncedSegments)
        ]
        for (key, field) in fields {
            for (text, expected) in [("YES", true), ("true", true), ("NO", false)] {
                defaults.removePersistentDomain(forName: suite)
                defaults.set(true, forKey: "excludePrivateBrowsing")
                defaults.set(text, forKey: key)
                var config = try AppConfig.loadOrCreateDefault(legacyConfigPaths: [], defaults: defaults)
                #expect(config[keyPath: field] == expected)
                config.serverURL = "https://journal.test"
                try config.save(to: defaults)
                #expect(defaults.object(forKey: key) as? Bool == expected)
                #expect(AppConfig.load(from: defaults)[keyPath: field] == expected)
            }
        }
    }

    @Test func legacyJSONDropsMaterializedDefaultsAndKeepsNondefaults() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jsonURL = dir.appendingPathComponent("config.json")
        let contDir = dir.appendingPathComponent("continuation", isDirectory: true)

        let json = """
        {
            "serverURL": "https://journal.test",
            "serverKey": "key-123",
            "excludePrivateBrowsing": true,
            "microphoneGain": 2.0,
            "syncPaused": true,
            "silenceMusic": false
        }
        """
        try Data(json.utf8).write(to: jsonURL)

        let suiteName = "test.appconfig.json.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let migrated = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [jsonURL],
            continuationDirectory: contDir,
            defaults: defaults
        )

        #expect(migrated.serverURL == "https://journal.test")
        #expect(migrated.serverKey == "key-123")
        #expect(defaults.object(forKey: "excludePrivateBrowsing") == nil)
        #expect(defaults.object(forKey: "microphoneGain") == nil)
        #expect(defaults.object(forKey: "syncPaused") as? Bool == true)
        #expect(defaults.object(forKey: "silenceMusic") as? Bool == false)
        #expect(migrated.excludePrivateBrowsing)
        #expect(migrated.microphoneGain == 2.0)
        try migrated.save(to: defaults)
        #expect(defaults.object(forKey: "excludePrivateBrowsing") == nil)
        #expect(defaults.object(forKey: "microphoneGain") == nil)
        #expect(defaults.object(forKey: "isScreenCaptureEnabled") as? Bool == true)
        #expect(defaults.object(forKey: "isMicrophoneCaptureEnabled") as? Bool == true)

        let absent = dir.appendingPathComponent("absent.json")
        let second = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: contDir,
            nativeSetupEnabled: true,
            defaults: defaults
        )
        #expect(!FileManager.default.fileExists(atPath: SetupContinuationStore(directory: contDir).fileURL.path))
        #expect(second.serverURL == "https://journal.test")
        #expect(second.serverKey == "key-123")
        #expect(defaults.object(forKey: "excludePrivateBrowsing") == nil)
        #expect(defaults.object(forKey: "microphoneGain") == nil)
        #expect(second.syncPaused)
        #expect(!second.silenceMusic)
    }

    @Test func legacyJSONRecordsPresenceBeforeImportCompletion() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jsonURL = dir.appendingPathComponent("config.json")
        try Data(#"{"serverURL":"https://journal.test","microphoneGain":3.5}"#.utf8).write(to: jsonURL)
        let suite = "test.appconfig.json-order.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [jsonURL], defaults: defaults
        )
        #expect(config.microphoneGain == 3.5)
        let presence = try #require(defaults.recordedEvents.firstIndex(where: {
            $0 == .setBool("didRecordConfigPresence", true) || $0 == .setAny("didRecordConfigPresence")
        }))
        let imported = try #require(defaults.recordedEvents.firstIndex(where: {
            $0 == .setBool("didMigrateFromJSON", true) || $0 == .setAny("didMigrateFromJSON")
        }))
        let converted = try #require(defaults.recordedEvents.firstIndex(where: {
            $0 == .setBool("didFinishOwnerScalarConversion", true) || $0 == .setAny("didFinishOwnerScalarConversion")
        }))
        #expect(presence < imported)
        #expect(imported < converted)
    }

    @Test func interruptedJSONImportResumesWithoutTheOldSentinel() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let continuation = dir.appendingPathComponent("continuation", isDirectory: true)
        let suite = "test.appconfig.json-interrupted.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Import finished, but scalar conversion has not. No legacy sentinel was present.
        defaults.set(true, forKey: "didRecordConfigPresence")
        defaults.set(true, forKey: "didMigrateFromJSON")
        defaults.set("https://journal.test", forKey: "serverURL")
        defaults.set(Float(2.0), forKey: "microphoneGain")
        defaults.set(true, forKey: "syncPaused")
        defaults.set(false, forKey: "isScreenCaptureEnabled")
        defaults.set(true, forKey: "isMicrophoneCaptureEnabled")

        let config = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [], continuationDirectory: continuation,
            nativeSetupEnabled: true, defaults: defaults
        )
        #expect(config.serverURL == "https://journal.test")
        #expect(config.syncPaused)
        #expect(!config.isScreenCaptureEnabled)
        #expect(config.isMicrophoneCaptureEnabled)
        #expect(defaults.object(forKey: "microphoneGain") == nil)
        #expect(defaults.bool(forKey: "didFinishOwnerScalarConversion"))
        #expect(!FileManager.default.fileExists(atPath: SetupContinuationStore(directory: continuation).fileURL.path))
    }

    @Test func interruptedDomainRecordingUserDefaults() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let absent = dir.appendingPathComponent("absent.json")
        let contDir = dir.appendingPathComponent("continuation", isDirectory: true)

        // Finish case
        let finishSuite = "test.appconfig.finish.\(UUID().uuidString)"
        let finishRecorder = try #require(RecordingUserDefaults(suiteName: finishSuite))
        defer { finishRecorder.removePersistentDomain(forName: finishSuite) }
        #expect(type(of: finishRecorder) == RecordingUserDefaults.self)

        finishRecorder.set(true, forKey: "didRecordConfigPresence")
        finishRecorder.set(true, forKey: "silenceMusic")
        finishRecorder.set(false, forKey: "debugSegments")
        finishRecorder.set(true, forKey: "syncPaused")
        finishRecorder.set(false, forKey: "isScreenCaptureEnabled")
        finishRecorder.set(true, forKey: "isMicrophoneCaptureEnabled")
        finishRecorder.set(true, forKey: "didMigrateFromJSON")
        finishRecorder.set(true, forKey: "didAdoptActivityFollowsScreen")
        finishRecorder.set(true, forKey: "didReseedCaptureSourcesOn")
        finishRecorder.set(true, forKey: "didReseedOptInMicrophones")
        finishRecorder.set(["bt-1"], forKey: "reseededBluetoothMicrophoneUIDs")
        finishRecorder.set(true, forKey: "didAddPasswordManagerExclusions")
        finishRecorder.set(false, forKey: "activityTitlesEnabled")

        let finishConfig = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: contDir,
            nativeSetupEnabled: true,
            defaults: finishRecorder
        )

        #expect(finishRecorder.object(forKey: "silenceMusic") == nil)
        #expect(finishRecorder.object(forKey: "debugSegments") == nil)
        #expect(finishRecorder.bool(forKey: "didFinishOwnerScalarConversion"))
        #expect(!finishConfig.isScreenCaptureEnabled)
        #expect(finishConfig.isMicrophoneCaptureEnabled)
        #expect(finishConfig.syncPaused == true)
        #expect(finishConfig.activityTitlesEnabled == false)
        #expect(finishRecorder.bool(forKey: "didMigrateFromJSON"))
        #expect(finishRecorder.bool(forKey: "didAdoptActivityFollowsScreen"))
        #expect(finishRecorder.bool(forKey: "didReseedCaptureSourcesOn"))
        #expect(finishRecorder.bool(forKey: "didReseedOptInMicrophones"))
        #expect(finishRecorder.stringArray(forKey: "reseededBluetoothMicrophoneUIDs") == ["bt-1"])
        #expect(finishRecorder.bool(forKey: "didAddPasswordManagerExclusions"))
        #expect(!FileManager.default.fileExists(atPath: SetupContinuationStore(directory: contDir).fileURL.path))

        // Order case
        let orderSuite = "test.appconfig.order.\(UUID().uuidString)"
        let orderRecorder = try #require(RecordingUserDefaults(suiteName: orderSuite))
        defer { orderRecorder.removePersistentDomain(forName: orderSuite) }
        let orderContDir = dir.appendingPathComponent("orderCont", isDirectory: true)

        orderRecorder.set(true, forKey: "excludePrivateBrowsing") // sentinel
        orderRecorder.set(true, forKey: "isBrowserIntakeEnabled")
        orderRecorder.set(false, forKey: "excludePrivateBrowsingAccessibility")
        orderRecorder.set(false, forKey: "activityAccessibilityEnabled")
        orderRecorder.set(false, forKey: "syncPaused")
        orderRecorder.set(false, forKey: "debugSegments")
        orderRecorder.set(false, forKey: "preserveSyncedSegments")
        orderRecorder.set(Float(2.0), forKey: "microphoneGain")
        orderRecorder.set(true, forKey: "silenceMusic")
        orderRecorder.set(true, forKey: "pauseForProtectedVideo")
        orderRecorder.set(true, forKey: "didMigrateFromJSON")

        orderRecorder.recordedEvents.removeAll()

        _ = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [absent],
            continuationDirectory: orderContDir,
            defaults: orderRecorder
        )

        #expect(!orderRecorder.recordedEvents.isEmpty)
        let presenceIdx = try #require(orderRecorder.recordedEvents.firstIndex(where: {
            $0 == .setBool("didRecordConfigPresence", true) || $0 == .setAny("didRecordConfigPresence")
        }))
        let removeSentinelIdx = try #require(orderRecorder.recordedEvents.firstIndex(where: {
            $0 == .remove("excludePrivateBrowsing")
        }))
        let completionIdx = try #require(orderRecorder.recordedEvents.lastIndex(where: {
            $0 == .setBool("didFinishOwnerScalarConversion", true) || $0 == .setAny("didFinishOwnerScalarConversion")
        }))

        let convertedKeySet = Set([
            "isBrowserIntakeEnabled", "excludePrivateBrowsing", "excludePrivateBrowsingAccessibility",
            "activityAccessibilityEnabled", "syncPaused", "debugSegments",
            "preserveSyncedSegments", "microphoneGain", "silenceMusic", "pauseForProtectedVideo"
        ])
        let lastRemovalIdx = try #require(orderRecorder.recordedEvents.lastIndex(where: {
            if case .remove(let key) = $0 { return convertedKeySet.contains(key) }
            return false
        }))

        #expect(presenceIdx < removeSentinelIdx)
        #expect(completionIdx > lastRemovalIdx)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-appconfig-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RecordingUserDefaults: UserDefaults, @unchecked Sendable {
    enum Event: Equatable {
        case setAny(String)
        case setBool(String, Bool)
        case setFloat(String, Float)
        case remove(String)
    }

    var recordedEvents: [Event] = []

    override init?(suiteName suitename: String?) {
        super.init(suiteName: suitename)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        recordedEvents.append(.setAny(defaultName))
        super.set(value, forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        recordedEvents.append(.setBool(defaultName, value))
        super.set(value, forKey: defaultName)
    }

    override func set(_ value: Float, forKey defaultName: String) {
        recordedEvents.append(.setFloat(defaultName, value))
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        recordedEvents.append(.remove(defaultName))
        super.removeObject(forKey: defaultName)
    }
}
