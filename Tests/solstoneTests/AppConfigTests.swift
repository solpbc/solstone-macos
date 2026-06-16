// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
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
}
