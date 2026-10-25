import Foundation
import MacTestSupport
import Testing
import SolstoneCore
@testable import solstone

@Suite("AppConfigMigration", .serialized)
@MainActor
struct AppConfigMigrationTests {
    @Test func serviceModeBundledRoundTripsThroughDefaults() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let config = AppConfig(serverURL: ServiceMode.bundledServiceURL, serverKey: "key", serviceMode: .bundled)
        try config.save()

        #expect(AppConfig.load().serviceMode == .bundled)
    }

    @Test func serviceModeExternalRoundTripsThroughDefaults() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let config = AppConfig(serverURL: "https://example.com", serverKey: "key", serviceMode: .external)
        try config.save()

        #expect(AppConfig.load().serviceMode == .external)
    }

    @Test func observerNameRoundTripsThroughDefaultsAndLoadsNilWhenMissing() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig(observerName: "observer-name")
        try config.save()
        #expect(AppConfig.load().observerName == "observer-name")

        config.observerName = nil
        try config.save()
        #expect(AppConfig.load().observerName == nil)
    }

    @Test func loadLeavesServiceModeNilForExactBundledURL() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let config = AppConfig(serverURL: ServiceMode.bundledServiceURL, serverKey: "key", serviceMode: nil)
        try config.save()
        UserDefaults.standard.removeObject(forKey: "serviceMode")

        let loaded = AppConfig.load()
        #expect(loaded.serviceMode == nil)
        #expect(UserDefaults.standard.string(forKey: "serviceMode") == nil)
    }

    @Test func loadLeavesServiceModeNilForExternalURL() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let config = AppConfig(serverURL: "https://example.com", serverKey: "key", serviceMode: nil)
        try config.save()
        UserDefaults.standard.removeObject(forKey: "serviceMode")

        let loaded = AppConfig.load()
        #expect(loaded.serviceMode == nil)
        #expect(UserDefaults.standard.string(forKey: "serviceMode") == nil)
    }

    @Test func aSavedTunnelPortLoadsAsNoJournalAddress() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let defaults = UserDefaults.standard
        defaults.set("http://127.0.0.1:50020", forKey: "serverURL")
        defaults.set("observer-key", forKey: "serverKey")
        defaults.set("external", forKey: "serviceMode")

        let loaded = AppConfig.load()
        #expect(loaded.serverURL == nil)
        #expect(loaded.serverKey == nil)
        #expect(!loaded.isUploadConfigured)
    }

    @Test(arguments: [ServiceMode.bundledServiceURL, "http://127.0.0.1:5015", "http://journal.local:5015", "https://example.com"])
    func aJournalAddressStillLoads(_ address: String) throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let defaults = UserDefaults.standard
        defaults.set(address, forKey: "serverURL")
        defaults.set("key", forKey: "serverKey")

        let loaded = AppConfig.load()
        #expect(loaded.serverURL == address)
        #expect(loaded.serverKey == "key")
        #expect(loaded.isUploadConfigured)
    }

    @Test func loadOrCreateDefaultMigratesJSONConfig() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let configURL = temp.appendingPathComponent("config.json")
        try Data("""
        {
          "serverURL": "https://example.com",
          "serverKey": "key",
          "excludePrivateBrowsing": false,
          "cacheRetentionDays": 14,
          "localRetentionMB": 500
        }
        """.utf8).write(to: configURL)

        let migrated = try AppConfig.loadOrCreateDefault(legacyConfigPaths: [configURL])

        #expect(migrated.serverURL == "https://example.com")
        #expect(migrated.serverKey == "key")
        #expect(UserDefaults.standard.bool(forKey: "didMigrateFromJSON"))
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
        #expect(FileManager.default.fileExists(atPath: configURL.appendingPathExtension("migrated").path))
    }

    @Test func userDefaultsHoldingLegacyRetentionKeysLoadsAndAppliesOtherFieldsWhileLeavingRetentionKeyUntouched() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        UserDefaults.standard.set(14, forKey: "cacheRetentionDays")
        UserDefaults.standard.set(500, forKey: "localRetentionMB")
        UserDefaults.standard.set("https://example.com/custom", forKey: "serverURL")

        let loaded = AppConfig.load()
        #expect(loaded.serverURL == "https://example.com/custom")
        #expect(UserDefaults.standard.integer(forKey: "cacheRetentionDays") == 14)
        #expect(UserDefaults.standard.integer(forKey: "localRetentionMB") == 500)
    }

    @Test func migrateLogsFilenameWithoutAccountPathComponent() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let account = "alice-account"
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let home = temp.appendingPathComponent("Users").appendingPathComponent(account)
        let configURL = home.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("""
        {
          "serverURL": "https://example.com",
          "serverKey": "key"
        }
        """.utf8).write(to: configURL)
        let log = RecordingClassifiedLogSink()

        _ = try AppConfig.loadOrCreateDefault(legacyConfigPaths: [configURL], log: log)

        let emission = try #require(log.emissions.first)
        let concatenated = emission.classification + emission.publicFields.values.joined() + emission.publicFields.keys.joined()
        #expect(!concatenated.contains(account))
        #expect(!concatenated.contains("/Users/\(account)"))
        #expect(emission.publicFields["filename"] == "config.json")
        #expect(emission.publicFields["source"] == "legacy-config")
    }

    @Test func optInMicrophoneReseedDoesNotRunWhenFlagIsSet() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        UserDefaults.standard.set(true, forKey: "didReseedOptInMicrophones")
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "continuity", name: "Continuity", isDisabled: false)
        ])

        config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: ["continuity"])

        #expect(config.microphonePriority[0].isDisabled == false)
    }

    @Test func optInMicrophoneReseedDemotesOnlyConnectedEnabledOptInEntries() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "continuity", name: "Continuity", isDisabled: false),
            MicrophoneEntry(uid: "usb", name: "USB", isDisabled: false),
            MicrophoneEntry(uid: "disabled-continuity", name: "Disabled Continuity", isDisabled: true)
        ])

        config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: ["continuity", "disabled-continuity"])

        #expect(config.microphonePriority[0].isDisabled)
        #expect(config.microphonePriority[1].isDisabled == false)
        #expect(config.microphonePriority[2].isDisabled)
        #expect(UserDefaults.standard.bool(forKey: "didReseedOptInMicrophones"))
    }

    @Test func optInMicrophoneReseedIsNoopOnSecondRun() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "continuity", name: "Continuity", isDisabled: false)
        ])

        config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: ["continuity"])
        #expect(config.microphonePriority[0].isDisabled)

        config.microphonePriority[0] = MicrophoneEntry(uid: "continuity", name: "Continuity", isDisabled: false)
        config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: ["continuity"])

        #expect(config.microphonePriority[0].isDisabled == false)
    }

    @Test func bluetoothReseedMovesEachHeadsetOnceWhenFirstSeenConnected() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "airpods", name: "AirPods", mode: .always),
            MicrophoneEntry(uid: "usb", name: "USB", mode: .always),
            MicrophoneEntry(uid: "headset-off", name: "Headset", mode: .off)
        ])
        config.reseedBluetoothMicrophones(connectedBluetoothUIDs: ["headset-off"])
        #expect(config.microphonePriority.map(\.mode) == [.always, .always, .off])
        // A headset that was away at upgrade still moves the first time it connects.
        config.reseedBluetoothMicrophones(connectedBluetoothUIDs: ["airpods", "headset-off"])
        #expect(config.microphonePriority.map(\.mode) == [.whenInUseElsewhere, .always, .off])
        #expect(config.disabledMicrophoneUIDs == ["headset-off"] && config.enabledMicrophoneUIDs == ["usb"])
        // A later owner choice is never revisited.
        config.setMicrophoneMode(uid: "airpods", mode: .always)
        config.reseedBluetoothMicrophones(connectedBluetoothUIDs: ["airpods"])
        #expect(config.microphonePriority[0].mode == .always)
    }

    @Test func microphoneModeRoundTripsAndOlderEntriesDecode() throws {
        let entries = [MicrophoneEntry(uid: "a", name: "A", mode: .whenInUseElsewhere),
                       MicrophoneEntry(uid: "b", name: "B", mode: .off), MicrophoneEntry(uid: "c", name: "C", mode: .always)]
        let decoded = try JSONDecoder().decode([MicrophoneEntry].self, from: JSONEncoder().encode(entries))
        #expect(decoded == entries && decoded.map(\.mode) == [.whenInUseElsewhere, .off, .always])
        let older = try JSONDecoder().decode(MicrophoneEntry.self, from: Data(#"{"uid":"x","name":"X","isDisabled":true}"#.utf8))
        #expect(older.mode == .off)
    }

    @Test func disconnectedBluetoothMicrophoneKeepsFollowingChoiceAfterModeChangesAndReload() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "headset", name: "Headset", mode: .always),
            MicrophoneEntry(uid: "usb", name: "USB", mode: .always)
        ])
        config.reseedBluetoothMicrophones(connectedBluetoothUIDs: ["headset"])
        for mode in [MicrophoneEntry.Mode.always, .off] {
            config.setMicrophoneMode(uid: "headset", mode: mode)
            try config.save()
            let reloaded = AppConfig.load()
            let headset = try #require(reloaded.microphonePriority.first(where: { $0.uid == "headset" }))
            #expect(headset.mode == mode)
            #expect(MicrophoneDisplayEntry(from: headset, isConnected: false).offersFollowing)
            let usb = try #require(reloaded.microphonePriority.first(where: { $0.uid == "usb" }))
            #expect(!MicrophoneDisplayEntry(from: usb, isConnected: false).offersFollowing)
        }
    }

    @Test func onlyABluetoothMicrophoneOnAlwaysCarriesTheCallModeNote() {
        let headset = { MicrophoneEntry(uid: "headset", name: "Headset", mode: $0) }
        #expect(MicrophoneDisplayEntry(from: headset(.always), isConnected: true, isBluetooth: true).showsCallModeNote)
        #expect(!MicrophoneDisplayEntry(from: headset(.whenInUseElsewhere), isConnected: true, isBluetooth: true).showsCallModeNote)
        #expect(!MicrophoneDisplayEntry(from: headset(.off), isConnected: true, isBluetooth: true).showsCallModeNote)
        let usb = MicrophoneEntry(uid: "usb", name: "USB", mode: .always)
        #expect(!MicrophoneDisplayEntry(from: usb, isConnected: true).showsCallModeNote)
    }

    // MARK: - Capture sources

    // 2.0.6 read an absent key as `false`, so every install that upgraded into it stopped
    // capturing. An absent key means "never chosen", which is on.
    @Test func absentCaptureSourceKeysLoadAsEnabled() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        let loaded = AppConfig.load()
        #expect(loaded.isScreenCaptureEnabled)
        #expect(loaded.isMicrophoneCaptureEnabled)
        #expect(loaded.selectedSources == [.screen, .microphone])
    }

    @Test func explicitlyDisabledCaptureSourcesSurviveLoad() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig()
        config.isScreenCaptureEnabled = false
        try config.save()

        let loaded = AppConfig.load()
        #expect(!loaded.isScreenCaptureEnabled)
        #expect(loaded.isMicrophoneCaptureEnabled)
    }

    // A 2.0.6 install that saved its config persisted both sources as off, so reading an
    // absent key as on cannot reach it. The one-shot repair does, exactly once.
    @Test func reseedTurnsBothSourcesBackOnExactlyOnce() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig()
        config.isScreenCaptureEnabled = false
        config.isMicrophoneCaptureEnabled = false
        try config.save()

        var repaired = AppConfig.load()
        repaired.reseedCaptureSourcesOnIfNeeded()
        #expect(repaired.isScreenCaptureEnabled)
        #expect(repaired.isMicrophoneCaptureEnabled)
        #expect(AppConfig.load().selectedSources == [.screen, .microphone])

        // A later deliberate both-off choice is the owner's, and the repair never fires again.
        var ownerChoice = AppConfig.load()
        ownerChoice.isScreenCaptureEnabled = false
        ownerChoice.isMicrophoneCaptureEnabled = false
        try ownerChoice.save()
        ownerChoice.reseedCaptureSourcesOnIfNeeded()
        #expect(!ownerChoice.isScreenCaptureEnabled)
        #expect(!ownerChoice.isMicrophoneCaptureEnabled)
    }

    @Test func reseedLeavesASingleDisabledSourceAlone() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig()
        config.isScreenCaptureEnabled = false
        try config.save()

        var loaded = AppConfig.load()
        loaded.reseedCaptureSourcesOnIfNeeded()
        #expect(!loaded.isScreenCaptureEnabled)
        #expect(loaded.isMicrophoneCaptureEnabled)
    }

    // An install set up before the password manager defaults gets them once, after the owner's
    // own list. A 1Password entry the owner took out stays out, and so does one taken out later.
    @Test func passwordManagerExclusionsReachAnExistingInstallOnce() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig()
        config.excludedApps = [
            AppEntry(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
            AppEntry(bundleID: "user.excluded.slack", name: "Slack")
        ]
        try config.save()

        var loaded = AppConfig.load()
        loaded.addPasswordManagerExclusionsIfNeeded()
        #expect(loaded.excludedApps == config.excludedApps + AppConfig.passwordManagerExclusions)
        #expect(!loaded.excludedApps.contains { $0.bundleID == "com.1password.1password" })
        #expect(AppConfig.load().excludedApps == loaded.excludedApps)

        var removed = AppConfig.load()
        removed.excludedApps.removeAll { $0 == AppConfig.passwordManagerExclusions[0] }
        try removed.save()
        removed.addPasswordManagerExclusionsIfNeeded()
        #expect(AppConfig.load().excludedApps == removed.excludedApps)
    }

    @Test func loadOrCreateDefaultFreshBranchInitializesSourcesFalseAndPhaseJournal() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [tempDir.appendingPathComponent("nonexistent.json")],
            continuationDirectory: tempDir,
            nativeSetupEnabled: true
        )

        #expect(!config.isScreenCaptureEnabled)
        #expect(!config.isMicrophoneCaptureEnabled)
        #expect(UserDefaults.standard.bool(forKey: "didReseedCaptureSourcesOn"))
        #expect(UserDefaults.standard.bool(forKey: "didAddPasswordManagerExclusions"))
        #expect(config.excludedApps == AppConfig.defaultExclusions)
        let store = SetupContinuationStore(directory: tempDir)
        #expect(store.load()?.phase == .journal)
    }

    // MARK: - Activity

    private static let activityKeys = ["isActivityEnabled", "activityTitlesEnabled", "activityURLsEnabled", "activityContinuesThroughPause"]

    @Test func freshInstallSavesNoActivityDefaultsAndKeepsAnOwnersOff() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let absent = [dir.appendingPathComponent("absent.json")]

        let config = try AppConfig.loadOrCreateDefault(legacyConfigPaths: absent, continuationDirectory: dir, nativeSetupEnabled: true)
        #expect(config.isActivityEnabled && config.activityTitlesEnabled && config.activityURLsEnabled)
        #expect(Self.activityKeys.allSatisfy { UserDefaults.standard.object(forKey: $0) == nil })
        #expect(UserDefaults.standard.bool(forKey: "didAdoptActivityFollowsScreen"))

        var owner = config
        owner.isActivityEnabled = false
        try owner.save()
        let relaunched = try AppConfig.loadOrCreateDefault(legacyConfigPaths: absent, continuationDirectory: dir, nativeSetupEnabled: true)
        #expect(!relaunched.isActivityEnabled)
    }

    @Test func existingInstallMovesToActivityFollowingScreenOnce() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let absent = [dir.appendingPathComponent("absent.json")]
        // What an earlier build left: a saved config with every activity value written as off.
        try AppConfig(isMicrophoneCaptureEnabled: false).save()
        for key in ["isActivityEnabled", "activityTitlesEnabled", "activityURLsEnabled"] {
            UserDefaults.standard.set(false, forKey: key)
        }
        UserDefaults.standard.set(true, forKey: "activityAccessibilityEnabled")

        let migrated = try AppConfig.loadOrCreateDefault(legacyConfigPaths: absent, continuationDirectory: dir)
        #expect(migrated.isActivityEnabled && migrated.activityTitlesEnabled && migrated.activityURLsEnabled)
        #expect(migrated.activityAccessibilityEnabled && !migrated.isMicrophoneCaptureEnabled)

        var owner = migrated
        owner.activityTitlesEnabled = false
        try owner.save()
        let relaunched = try AppConfig.loadOrCreateDefault(legacyConfigPaths: absent, continuationDirectory: dir)
        #expect(!relaunched.activityTitlesEnabled && relaunched.isActivityEnabled)
    }

    @Test func unqualifiedFreshInstallRetainsLegacyDefaultsWithoutCreatingSetupProgress() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [dir.appendingPathComponent("absent.json")],
            continuationDirectory: dir
        )
        #expect(config.isScreenCaptureEnabled)
        #expect(config.isMicrophoneCaptureEnabled)
        #expect(!FileManager.default.fileExists(atPath: SetupContinuationStore(directory: dir).fileURL.path))
    }

    @Test(arguments: [false, true])
    func setupQualificationPreservesExistingOwnerSelections(nativeSetupEnabled: Bool) throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: true).save()
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .screen))
        let progress = try Data(contentsOf: store.fileURL)
        let config = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [dir.appendingPathComponent("absent.json")],
            continuationDirectory: dir,
            nativeSetupEnabled: nativeSetupEnabled
        )
        #expect(!config.isScreenCaptureEnabled)
        #expect(config.isMicrophoneCaptureEnabled)
        #expect(try Data(contentsOf: store.fileURL) == progress)
    }

    @Test func failedNativeProgressWriteLeavesFreshInitializationRetryable() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocked = SetupContinuationStore(directory: dir, replace: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        #expect(throws: CocoaError.self) {
            try AppConfig.loadOrCreateDefault(
                legacyConfigPaths: [], nativeSetupEnabled: true, continuationStore: blocked
            )
        }
        #expect(UserDefaults.standard.object(forKey: "excludePrivateBrowsing") == nil)
        #expect(UserDefaults.standard.object(forKey: "didReseedCaptureSourcesOn") == nil)
        #expect(try blocked.loadChecked() == nil)

        let config = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [], nativeSetupEnabled: true,
            continuationStore: SetupContinuationStore(directory: dir)
        )
        #expect(!config.isScreenCaptureEnabled)
        #expect(!config.isMicrophoneCaptureEnabled)
        #expect(try blocked.loadChecked()?.phase == .journal)
        #expect(UserDefaults.standard.object(forKey: "excludePrivateBrowsing") != nil)
        #expect(UserDefaults.standard.bool(forKey: "didReseedCaptureSourcesOn"))
    }

    @Test func interruptedFreshInitializationPreservesExistingProgress() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { clearConfigDefaults() }
        let store = SetupContinuationStore(directory: dir)
        for record in [
            SetupContinuation(phase: .journal),
            SetupContinuation(phase: .screen),
            SetupContinuation(completed: true),
        ] {
            clearConfigDefaults()
            try store.save(record)
            let before = try Data(contentsOf: store.fileURL)
            let refusingReplacement = SetupContinuationStore(directory: dir, replace: { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            })
            let config = try AppConfig.loadOrCreateDefault(
                legacyConfigPaths: [], nativeSetupEnabled: true,
                continuationStore: refusingReplacement
            )
            #expect(!config.isScreenCaptureEnabled)
            #expect(!config.isMicrophoneCaptureEnabled)
            #expect(try Data(contentsOf: store.fileURL) == before)
        }
    }

    @Test func corruptNativeProgressIsPreservedAndBlocksFreshPreferences() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        let corrupt = Data("incomplete progress".utf8)
        try corrupt.write(to: store.fileURL)
        #expect(throws: DecodingError.self) {
            try AppConfig.loadOrCreateDefault(
                legacyConfigPaths: [], nativeSetupEnabled: true, continuationStore: store
            )
        }
        #expect(try Data(contentsOf: store.fileURL) == corrupt)
        #expect(UserDefaults.standard.object(forKey: "excludePrivateBrowsing") == nil)
        #expect(UserDefaults.standard.object(forKey: "didReseedCaptureSourcesOn") == nil)
    }

    @Test func unreadableNativeProgressDoesNotBecomeAbsentProgress() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try AppConfig.loadOrCreateDefault(
                legacyConfigPaths: [], nativeSetupEnabled: true, continuationStore: store
            )
        }
        #expect(UserDefaults.standard.object(forKey: "excludePrivateBrowsing") == nil)
        #expect(UserDefaults.standard.object(forKey: "didReseedCaptureSourcesOn") == nil)
        #expect((try store.fileURL.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
    }

    @Test func existingAndDisabledOwnersNeverConsultNativeProgress() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        let corrupt = Data("unreadable as progress".utf8)
        try corrupt.write(to: store.fileURL)
        let legacy = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [], nativeSetupEnabled: false, continuationStore: store
        )
        #expect(legacy.isScreenCaptureEnabled)
        #expect(legacy.isMicrophoneCaptureEnabled)
        try AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: true).save()
        let existing = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [], nativeSetupEnabled: true, continuationStore: store
        )
        #expect(!existing.isScreenCaptureEnabled)
        #expect(existing.isMicrophoneCaptureEnabled)
        #expect(try Data(contentsOf: store.fileURL) == corrupt)
    }

    @Test func nativeQualificationDoesNotBootstrapAMigratedOwner() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.json")
        try Data("{\"serverURL\":\"https://journal.example.test\",\"serverKey\":\"fixture\"}".utf8).write(to: configURL)
        let blocked = SetupContinuationStore(directory: dir, replace: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let migrated = try AppConfig.loadOrCreateDefault(
            legacyConfigPaths: [configURL], nativeSetupEnabled: true, continuationStore: blocked
        )
        #expect(migrated.serverURL == "https://journal.example.test")
        #expect(try blocked.loadChecked() == nil)
        #expect(FileManager.default.fileExists(atPath: configURL.appendingPathExtension("migrated").path))
    }

    @Test func missingSourceKeysStillLoadTrue() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        UserDefaults.standard.set(true, forKey: "excludePrivateBrowsing")
        let loaded = AppConfig.load()
        #expect(loaded.isScreenCaptureEnabled)
        #expect(loaded.isMicrophoneCaptureEnabled)
    }

    @Test func flagUnsetAndBothOffStillReseedsBothOn() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false)
        try config.save()
        UserDefaults.standard.removeObject(forKey: "didReseedCaptureSourcesOn")

        var loaded = AppConfig.load()
        #expect(!loaded.isScreenCaptureEnabled)
        #expect(!loaded.isMicrophoneCaptureEnabled)

        loaded.reseedCaptureSourcesOnIfNeeded()
        #expect(loaded.isScreenCaptureEnabled)
        #expect(loaded.isMicrophoneCaptureEnabled)
        #expect(UserDefaults.standard.bool(forKey: "didReseedCaptureSourcesOn"))
    }

    @Test func flagUnsetAndOneSourceOnOnlySetsTheFlag() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: false)
        try config.save()
        UserDefaults.standard.removeObject(forKey: "didReseedCaptureSourcesOn")

        var loaded = AppConfig.load()
        loaded.reseedCaptureSourcesOnIfNeeded()
        #expect(loaded.isScreenCaptureEnabled)
        #expect(!loaded.isMicrophoneCaptureEnabled)
        #expect(UserDefaults.standard.bool(forKey: "didReseedCaptureSourcesOn"))
    }

    @Test func flagAlreadyTrueAndBothOffStaysOff() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false)
        try config.save()
        UserDefaults.standard.set(true, forKey: "didReseedCaptureSourcesOn")

        var loaded = AppConfig.load()
        loaded.reseedCaptureSourcesOnIfNeeded()
        #expect(!loaded.isScreenCaptureEnabled)
        #expect(!loaded.isMicrophoneCaptureEnabled)
    }

    private func clearServiceDefaults() {
        for key in ["serverURL", "serverKey", "serviceMode"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func clearConfigDefaults() {
        for key in AppConfig.knownKeys + [
            "didMigrateFromJSON",
            "didReseedNotificationPreference",
            "solInitiatedChatNotificationsEnabled",
            "didReseedOptInMicrophones",
            "reseededBluetoothMicrophoneUIDs",
            "didReseedCaptureSourcesOn",
            "didAddPasswordManagerExclusions",
            "didAdoptActivityFollowsScreen",
            "localRetentionMB"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-app-config-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
