// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreAudio
import os
import SwiftUI
import Testing
import UserNotifications
import SolstoneCore
import UpdateKit
@testable import solstone

private func runGit(_ args: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = Array(args)
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func makeSnapshotOutputDir() throws -> URL {
    let repoRoot = try runGit("rev-parse", "--show-toplevel")
    let gitHash = try runGit("rev-parse", "--short", "HEAD")

    let dirtyCheck = Process()
    dirtyCheck.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    dirtyCheck.arguments = ["diff", "--quiet", "HEAD"]
    dirtyCheck.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
    try dirtyCheck.run()
    dirtyCheck.waitUntilExit()
    let isDirty = dirtyCheck.terminationStatus != 0

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    let dirName = "\(formatter.string(from: Date()))_\(gitHash)\(isDirty ? "-dirty" : "")"

    let url = URL(fileURLWithPath: repoRoot).appendingPathComponent("snapshots/\(dirName)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Snapshots")
@MainActor
struct SnapshotTests {
    private let isolatedDefaults = IsolatedUserDefaults()

    private static nonisolated(unsafe) var _outputDir: URL?

    private var outputDir: URL {
        get throws {
            if let dir = Self._outputDir { return dir }
            let dir = try makeSnapshotOutputDir()
            Self._outputDir = dir
            return dir
        }
    }

    init() {
        _ = NSApplication.shared
    }

    private func makeSnapshotUpdateController() -> UpdateController {
        UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: Logger.setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: isolatedDefaults.defaults
        ) { _, _ in nil }
    }

    private func render<V: View>(
        _ view: V,
        size: CGSize,
        to filename: String,
        appearance: NSAppearance? = nil
    ) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = appearance
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderError.noBitmap
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw RenderError.noPNG
        }

        let url = try outputDir.appendingPathComponent(filename)
        try pngData.write(to: url)

        guard let bitmapData = bitmapRep.bitmapData else { return }
        let bytesPerPixel = bitmapRep.bitsPerPixel / 8
        let bytesPerRow = bitmapRep.bytesPerRow
        let width = bitmapRep.pixelsWide
        let height = bitmapRep.pixelsHigh
        var backgroundCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bitmapData.advanced(by: y * bytesPerRow + x * bytesPerPixel)
                if pixel[0] >= 250, pixel[1] >= 250, pixel[2] >= 250 {
                    backgroundCount += 1
                }
            }
        }
        let whiteRatio = Double(backgroundCount) / Double(width * height)
        if whiteRatio > emptinessThreshold {
            throw RenderError.emptyContent(filename: filename, whiteRatio: whiteRatio, threshold: emptinessThreshold)
        }
    }

    private enum RenderError: Error, CustomStringConvertible {
        case noBitmap
        case noPNG
        case emptyContent(filename: String, whiteRatio: Double, threshold: Double)

        var description: String {
            switch self {
            case .noBitmap: return "failed to create bitmap rep"
            case .noPNG: return "failed to encode PNG"
            case let .emptyContent(filename, whiteRatio, threshold):
                return "\(filename): \(String(format: "%.3f", whiteRatio)) near-white exceeds \(String(format: "%.2f", threshold)) threshold"
            }
        }
    }

    private let menuSize = CGSize(width: 250, height: 350)

    private func markPermissionsReady(_ state: AppState) {
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.granted)
        state.microphoneAuthorizationCause = .authorized
    }

    private let statusIconSize = CGSize(width: 28, height: 28)

    private func statusIconSnapshot(icon: MenubarIconState, overlay: MenubarIconOverlayState) -> some View {
        MenubarIconGlyphView(icon: icon, overlay: overlay)
            .frame(width: 20, height: 20)
            .padding(4)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @Test func statusIconAttentionHaloLight() throws {
        try render(
            statusIconSnapshot(icon: .recording, overlay: .attention),
            size: statusIconSize,
            to: "status-icon-attention-light.png",
            appearance: try #require(NSAppearance(named: .aqua))
        )
    }

    @Test func statusIconAttentionHaloDark() throws {
        try render(
            statusIconSnapshot(icon: .recording, overlay: .attention),
            size: statusIconSize,
            to: "status-icon-attention-dark.png",
            appearance: try #require(NSAppearance(named: .darkAqua))
        )
    }

    @Test func statusIconClear() throws {
        try render(
            statusIconSnapshot(icon: .recording, overlay: .none),
            size: statusIconSize,
            to: "status-icon-clear.png",
            appearance: try #require(NSAppearance(named: .aqua))
        )
    }

    @Test func statusIconBundledJournalBadging() throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        markPermissionsReady(state)
        state.isRecording = true
        let presentation = state.menubarPresentation(durableUpdateStatus: .idle)
        #expect(presentation.attention == .journal)
        #expect(presentation.overlayState == .attention)

        try render(
            statusIconSnapshot(icon: presentation.icon, overlay: presentation.overlayState),
            size: statusIconSize,
            to: "status-icon-bundled-journal-badging.png",
            appearance: try #require(NSAppearance(named: .aqua))
        )
    }

    @Test func statusIconUpdateAvailableRecordingBadging() throws {
        let state = AppState.forSnapshot(config: AppConfig(
            serverURL: "https://solstone.example.com",
            serverKey: "sk-test-key-1234",
            serviceMode: .external
        ))
        markPermissionsReady(state)
        state.isRecording = true
        state.uploadCoordinator.status = .synced
        let presentation = state.menubarPresentation(
            durableUpdateStatus: .available(version: "1.3.9", releaseNotes: nil)
        )
        #expect(presentation.icon == .recording)
        #expect(presentation.attention == .updateAvailable)
        #expect(presentation.overlayState == .attention)

        try render(
            statusIconSnapshot(icon: presentation.icon, overlay: presentation.overlayState),
            size: statusIconSize,
            to: "status-icon-update-available-recording.png",
            appearance: try #require(NSAppearance(named: .aqua))
        )
    }

    @Test func menuStarting() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-starting.png")
    }

    @Test func menuObservingFullExternal() throws {
        let config = AppConfig(serverURL: "https://solstone.example.com", serverKey: "sk-test-key-1234")
        let state = AppState.forSnapshot(config: config)
        markPermissionsReady(state)
        state.isRecording = true
        state.uploadCoordinator.status = .synced
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-observing-full-external.png")
    }

    @Test func menuObservingFullBundled() throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        markPermissionsReady(state)
        state.isRecording = true
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-observing-full-bundled.png")
    }

    @Test func menuObservingHalfOffline() throws {
        let config = AppConfig(serverURL: "https://solstone.example.com", serverKey: "sk-test-key-1234")
        let state = AppState.forSnapshot(config: config)
        markPermissionsReady(state)
        state.isRecording = true
        state.uploadCoordinator.status = .notSynced
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-observing-half-offline.png")
    }

    @Test func menuObservingHalfSyncPaused() throws {
        let config = AppConfig(
            serverURL: "https://solstone.example.com",
            serverKey: "sk-test-key-1234",
            syncPaused: true
        )
        let state = AppState.forSnapshot(config: config)
        markPermissionsReady(state)
        state.isRecording = true
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-observing-half-sync-paused.png")
    }

    @Test func menuObservingHalfLocalOnly() throws {
        let state = AppState.forSnapshot()
        markPermissionsReady(state)
        state.isRecording = true
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-observing-half-local-only.png")
    }

    @Test func menuObservingHalfBundledUnhealthy() throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        markPermissionsReady(state)
        state.isRecording = true
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-observing-half-bundled-unhealthy.png")
    }

    @Test func menuObservingHalfStoppedByUser() throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        markPermissionsReady(state)
        state.isRecording = true
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-observing-half-stopped-by-user.png")
    }

    @Test func menuPaused() throws {
        let state = AppState.forSnapshot()
        markPermissionsReady(state)
        state.isRecording = true
        state.pauseManager.pause(for: .seconds(125))
        let expectedHeader = pausedHeaderText(timeRemaining: state.pauseManager.formatTimeRemaining())
        #expect(expectedHeader.hasPrefix("paused, "))
        #expect(expectedHeader.hasSuffix(" left"))
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-paused.png")
    }

    @Test func menuPausedShort() throws {
        let longState = AppState.forSnapshot()
        markPermissionsReady(longState)
        longState.isRecording = true
        longState.pauseManager.pause(for: .seconds(125))
        let headerLong = pausedHeaderText(timeRemaining: longState.pauseManager.formatTimeRemaining())

        let state = AppState.forSnapshot()
        markPermissionsReady(state)
        state.isRecording = true
        state.pauseManager.pause(for: .seconds(35))
        let expectedHeader = pausedHeaderText(timeRemaining: state.pauseManager.formatTimeRemaining())
        #expect(expectedHeader.hasPrefix("paused, "))
        #expect(expectedHeader.hasSuffix(" left"))
        #expect(headerLong != expectedHeader)
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-paused-short.png")
    }

    @Test func menuPausedIndefinite() throws {
        let state = AppState.forSnapshot()
        markPermissionsReady(state)
        state.isRecording = true
        state.pauseManager.pause(for: .indefinite)
        #expect(pausedHeaderText(timeRemaining: state.pauseManager.formatTimeRemaining()) == "paused")
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-paused-indefinite.png")
    }

    @Test func menuError() throws {
        let state = AppState.forSnapshot()
        state.errorMessage = "Screen recording permission denied"
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-error.png")
    }

    @Test func menuErrorPermissions() throws {
        let state = AppState.forSnapshot()
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.notGranted)
        state.microphoneAuthorizationCause = .denied
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-error-permissions.png")
    }

    @Test func menuErrorWedge() throws {
        let state = AppState.forSnapshot()
        markPermissionsReady(state)
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-error-wedge.png")
    }

    private let settingsSize = CGSize(width: 800, height: 560)
    private let emptinessThreshold = 0.95  // blank-pane regressions (5fd16e5) rendered ~99% near-white; healthy snapshots stay below ~85%

    @Test func settingsObserver() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .observer, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-observer.png"
        )
    }

    @Test func settingsObserverAuthorizedNotifications() throws {
        let state = AppState.forSnapshot(notificationStatus: .authorized)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .observer, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-observer-notifications-authorized.png"
        )
    }

    @Test func settingsObserverDeniedNotifications() throws {
        let state = AppState.forSnapshot(notificationStatus: .denied)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .observer, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-observer-notifications-denied.png"
        )
    }

    @Test func settingsObserverProvisionalNotifications() throws {
        let state = AppState.forSnapshot(notificationStatus: .provisional)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .observer, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-observer-notifications-provisional.png"
        )
    }

    @Test func settingsServiceEmpty() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .service, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-service-empty.png"
        )
    }

    @Test func settingsServicePermissionsAttention() throws {
        let state = AppState.forSnapshot()
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.notGranted)
        state.microphoneAuthorizationCause = .authorized
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .service, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-service-permissions-attention.png"
        )
    }

    @Test func settingsServiceConfigured() throws {
        var config = AppConfig(serverURL: "https://solstone.example.com")
        config.serverKey = "sk-test-key-1234"
        let state = AppState.forSnapshot(config: config)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .service, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-service-configured.png"
        )
    }

    @Test func settingsServiceYourJournalConfigured() throws {
        let config = AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "sk-test-key-1234",
            serviceMode: .external
        )
        let state = AppState.forSnapshot(config: config)
        state.setConfirmedMark(.uiTestSample)
        state.uploadCoordinator.status = .synced
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .service,
                initialStorageUsedMB: 42,
                initialJournalName: "field journal"
            ),
            size: settingsSize,
            to: "settings-service-your-journal-configured.png"
        )
    }

    @Test func settingsServiceRelayUnavailable() throws {
        let config = AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "sk-test-key-1234",
            serviceMode: .external
        )
        let state = AppState.forSnapshot(
            config: config,
            initialTunnelPairing: pairing(relayEnrollment: .unavailable)
        )
        state.setConfirmedMark(.uiTestSample)
        state.uploadCoordinator.status = .synced
        #expect(state.tunnelLifecycleOwner.relayAccessStatus == .unavailable)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .service,
                initialStorageUsedMB: 42,
                initialJournalName: "field journal",
                initialShowPairingFlow: true
            ),
            // This paired relay state repeats the journal mark inside pairing, so it needs a taller canvas.
            size: CGSize(width: settingsSize.width, height: 780),
            to: "settings-service-relay-unavailable.png"
        )
    }

    @Test func settingsServiceYourJournalUnconfigured() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .service,
                initialStorageUsedMB: 42,
                initialLocalDiscoveryCompleted: false,
                localIdentityFetch: { _ in nil }
            ),
            size: settingsSize,
            to: "settings-service-your-journal-unconfigured.png"
        )
    }

    @Test func settingsServiceYourJournalFork() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .service,
                initialStorageUsedMB: 42,
                initialLocalDiscoveryCompleted: true
            ),
            size: settingsSize,
            to: "settings-service-your-journal-fork.png"
        )
    }

    @Test func settingsServiceFoundLocalJournal() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .service,
                initialStorageUsedMB: 42,
                initialLocalJournalMark: .uiTestSample,
                initialLocalDiscoveryCompleted: true
            ),
            size: settingsSize,
            to: "settings-service-found-local-journal.png"
        )
    }

    @Test func settingsServiceMigrationBanner() throws {
        let config = AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "sk-test-key-1234",
            serviceMode: .bundled
        )
        let state = AppState.forSnapshot(config: config)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .service,
                initialStorageUsedMB: 42,
                initialJournalName: "field journal"
            ),
            size: settingsSize,
            to: "settings-service-migration-banner.png"
        )
    }

    @Test func settingsMicrophones() throws {
        let config = AppConfig(
            microphonePriority: [
                MicrophoneEntry(uid: "uid-builtin", name: "MacBook Pro Microphone"),
                MicrophoneEntry(uid: "uid-usb", name: "Blue Yeti"),
                MicrophoneEntry(uid: "uid-bt", name: "AirPods Pro", isDisabled: true),
            ],
            microphoneGain: 2.0
        )
        let state = AppState.forSnapshot(config: config)
        let updateController = makeSnapshotUpdateController()
        state.audioDeviceMonitor.availableDevices = [
            AudioInputDevice(
                id: AudioDeviceID(1),
                name: "MacBook Pro Microphone",
                uid: "uid-builtin",
                manufacturer: "Apple Inc.",
                sampleRate: 48000,
                transportType: .builtin
            )
        ]
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .microphones),
            size: settingsSize,
            to: "settings-microphones.png"
        )
    }

    @Test func settingsMicrophonesEmpty() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .microphones),
            size: settingsSize,
            to: "settings-microphones-empty.png"
        )
    }

    @Test func settingsPrivacy() throws {
        let config = AppConfig(
            excludedApps: [
                AppEntry(bundleID: "com.1password.1password", name: "1Password"),
                AppEntry(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
            ],
            excludedTitlePatterns: ["reddit"],
            excludePrivateBrowsing: true
        )
        let state = AppState.forSnapshot(config: config)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .privacy),
            size: settingsSize,
            to: "settings-privacy.png"
        )
    }

    @Test func settingsPrivacyEmpty() throws {
        let config = AppConfig(
            excludedApps: [],
            excludedTitlePatterns: [],
            excludePrivateBrowsing: false
        )
        let state = AppState.forSnapshot(config: config)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .privacy),
            size: settingsSize,
            to: "settings-privacy-empty.png"
        )
    }

    @Test func settingsStatusStarting() throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let updateController = makeSnapshotUpdateController()
        state.uploadCoordinator.status = .synced
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .status, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-status-starting.png"
        )
    }

    @Test func settingsStatusRecording() throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let updateController = makeSnapshotUpdateController()
        markPermissionsReady(state)
        state.isRecording = true
        state.uploadCoordinator.status = .syncing(checked: 3, total: 10)
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .status, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-status-recording.png"
        )
    }

    @Test func settingsStatusSetupReady() throws {
        let store = InMemoryLastSuccessfulJournalContactStore()
        let deliveryStore = InMemoryLastJournalDeliveryStore()
        let state = AppState.forSnapshot(config: AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "observer-key",
            serviceMode: .external
        ), lastContactStore: store, lastDeliveryStore: deliveryStore)
        markPermissionsReady(state)
        state.isRecording = true
        state.uploadCoordinator.status = .synced
        let recentDate = Date(timeIntervalSinceNow: -120)
        let fingerprint = try #require(state.currentJournalIdentity().fingerprint?.value)
        store.write(LastSuccessfulJournalContactPayload(date: recentDate, fingerprint: fingerprint))
        #expect(deliveryStore.write(LastJournalDeliveryPayload(
            date: recentDate,
            fingerprint: fingerprint
        )) == .confirmed)
        state.uploadCoordinator.refreshLastSuccessfulJournalContact()
        state.uploadCoordinator.refreshLastJournalDelivery()
        #expect(state.uploadCoordinator.lastSuccessfulJournalContactOutcome == .synced(recentDate))
        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .delivered(recentDate))
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .status,
                initialStorageUsedMB: 42,
                initialSetupProbeSnapshot: setupProbeSnapshot(
                    solAppPlacement: .ready,
                    journalAppInstalled: .ready,
                    solWrapperExecutable: .ready,
                    journalWrapperExecutable: .ready
                )
            ),
            size: settingsSize,
            to: "settings-status-setup-ready.png"
        )
    }

    @Test func settingsStatusSetupNeedsAttention() throws {
        let state = AppState.forSnapshot()
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.notGranted)
        state.microphoneAuthorizationCause = .denied
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .status,
                initialStorageUsedMB: 42,
                initialSetupProbeSnapshot: setupProbeSnapshot(
                    solAppPlacement: .needsAttention,
                    journalAppInstalled: .needsAttention,
                    solWrapperExecutable: .needsAttention,
                    journalWrapperExecutable: .needsAttention,
                    hasPromptedScreenRecording: true,
                    screenDiagnostic: ScreenRecordingPermissionDiagnostic(
                        preflightSucceeded: false,
                        sckFailedAfterPositivePreflight: false
                    )
                )
            ),
            size: settingsSize,
            to: "settings-status-setup-needs-attention.png"
        )
    }

    @Test func settingsStatusSetupUnavailable() throws {
        let state = AppState.forSnapshot(config: AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "observer-key",
            serviceMode: .external
        ))
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.notGranted)
        state.microphoneAuthorizationCause = .authorized
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .status,
                initialStorageUsedMB: 42,
                initialSetupProbeSnapshot: setupProbeSnapshot(
                    solAppPlacement: .ready,
                    journalAppInstalled: .unavailable,
                    solWrapperExecutable: .ready,
                    journalWrapperExecutable: .ready,
                    screenDiagnostic: ScreenRecordingPermissionDiagnostic(
                        preflightSucceeded: true,
                        sckFailedAfterPositivePreflight: true
                    )
                )
            ),
            size: settingsSize,
            to: "settings-status-setup-unavailable.png"
        )
    }

    @Test func settingsStatusError() throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let updateController = makeSnapshotUpdateController()
        state.errorMessage = "observation stopped unexpectedly — try again to resume."
        #expect(state.observationRowState == .error)
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .status, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-status-error.png"
        )
    }

    // Intentionally no settings-status-error-inflight.png snapshot: tryAgainInFlight
    // is view-local SettingsView @State with no init hook, and statusTab is private.
    // Exercising it would require a production seam; this task only permits the
    // tunnel pairing injection seam above.

    @Test func settingsUpdatesFailedArm() throws {
        let controller = UpdateController(
            feedURL: "https://updates.solstone.app/solstone-macos/appcast.xml",
            publicKey: "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho=",
            log: Logger.setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: isolatedDefaults.defaults
        ) { _, _ in nil }
        #expect(controller.canCheckForUpdates)
        #expect(controller.updaterArmState == .failedToArm(reason: "the update system couldn't be prepared."))
        try render(
            SettingsView(appState: AppState.forSnapshot(), updateController: controller, selectedTab: .updates),
            size: settingsSize,
            to: "settings-updates-failed-arm.png"
        )
    }

    @Test func settingsPermissions() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .permissions),
            size: settingsSize,
            to: "settings-permissions.png"
        )
    }

    @Test func settingsPermissionsRecovery() throws {
        let state = AppState.forSnapshot()
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.notGranted)
        state.microphoneAuthorizationCause = .authorized
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .permissions,
                initialSetupProbeSnapshot: setupProbeSnapshot(
                    hasPromptedScreenRecording: true,
                    screenDiagnostic: ScreenRecordingPermissionDiagnostic(
                        preflightSucceeded: false,
                        sckFailedAfterPositivePreflight: false
                    )
                )
            ),
            size: settingsSize,
            to: "settings-permissions-recovery.png"
        )
    }

    @Test func settingsPermissionsCDHashRecovery() throws {
        let state = AppState.forSnapshot()
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.notGranted)
        state.microphoneAuthorizationCause = .authorized
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .permissions,
                initialSetupProbeSnapshot: setupProbeSnapshot(
                    hasPromptedScreenRecording: false,
                    screenDiagnostic: ScreenRecordingPermissionDiagnostic(
                        preflightSucceeded: true,
                        sckFailedAfterPositivePreflight: true
                    )
                )
            ),
            size: settingsSize,
            to: "settings-permissions-cdhash-recovery.png"
        )
    }

    @Test func settingsHelp() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .help),
            size: settingsSize,
            to: "settings-help.png"
        )
    }

    @Test func settingsHelpDiagnosticsExpanded() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let report = buildDiagnosticReport(DiagnosticReportInput(
            appVersion: AppVersion.short,
            screenRecording: .granted,
            microphone: .granted,
            isRecording: true,
            isPaused: false,
            hasError: false,
            lastDelivery: .delivered(now.addingTimeInterval(-120)),
            lastJournalContact: .synced(now.addingTimeInterval(-30)),
            evidence: .available(DiagnosticEvidenceEnvelope(
                schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
                entries: [
                    DiagnosticEvidenceEntry(
                        code: .appLaunch,
                        firstAt: now.addingTimeInterval(-300),
                        lastAt: now.addingTimeInterval(-300),
                        repeatCount: 1
                    ),
                    DiagnosticEvidenceEntry(
                        code: .captureOn,
                        firstAt: now.addingTimeInterval(-60),
                        lastAt: now.addingTimeInterval(-60),
                        repeatCount: 1
                    )
                ]
            )),
            now: now
        ))
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(
                appState: state,
                updateController: updateController,
                selectedTab: .help,
                initialDiagnosticsExpanded: true,
                initialDiagnosticReport: report
            ),
            size: settingsSize,
            to: "settings-help-diagnostics-expanded.png"
        )
    }

    private let aboutSize = CGSize(width: 300, height: 390)

    @Test func about() throws {
        try render(AboutView(), size: aboutSize, to: "about.png")
    }

    private func setupProbeSnapshot(
        solAppPlacement: SetupProbeOutcome = .ready,
        journalAppInstalled: SetupProbeOutcome = .ready,
        solWrapperExecutable: SetupProbeOutcome = .ready,
        journalWrapperExecutable: SetupProbeOutcome = .ready,
        hasPromptedScreenRecording: Bool = false,
        screenDiagnostic: ScreenRecordingPermissionDiagnostic? = nil
    ) -> SetupProbeSnapshot {
        SetupProbeSnapshot(
            solAppPlacement: solAppPlacement,
            journalAppInstalled: journalAppInstalled,
            solWrapperExecutable: solWrapperExecutable,
            journalWrapperExecutable: journalWrapperExecutable,
            hasPromptedScreenRecording: hasPromptedScreenRecording,
            screenDiagnostic: screenDiagnostic
        )
    }

    @Test func emptinessGuardFiresOnBlankView() {
        #expect {
            try render(Color.white, size: settingsSize, to: "blank-view-guard.png")
        } throws: { error in
            guard case RenderError.emptyContent = error else { return false }
            return true
        }
    }
}
