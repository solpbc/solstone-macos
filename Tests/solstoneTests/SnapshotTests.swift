// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreAudio
import SwiftUI
import Testing
import SolstoneCore
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
        UpdateController(feedURL: nil, publicKey: nil) { _, _ in nil }
    }

    private func render<V: View>(_ view: V, size: CGSize, to filename: String) throws {
        let hostingView = NSHostingView(rootView: view)
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

    @Test func menuIdle() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-idle.png")
    }

    @Test func menuSolPinged() throws {
        let state = AppState.forSnapshot()
        state.solChatPending = SolChatRequestSummary(
            id: "req-test",
            summary: "let's pick up where we left off on the recorder",
            day: "2026-05-09",
            eventIndex: 42,
            receivedAt: Date(timeIntervalSince1970: 0)
        )
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-sol-pinged.png")
    }

    @Test func menuRecording() throws {
        let state = AppState.forSnapshot()
        state.isRecording = true
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-recording.png")
    }

    @Test func menuPaused() throws {
        let state = AppState.forSnapshot()
        state.isRecording = true
        state.pauseManager.pause(for: .seconds(125))
        let expectedHeader = pausedHeaderText(timeRemaining: state.pauseManager.formatTimeRemaining())
        #expect(expectedHeader.hasPrefix("paused - "))
        #expect(expectedHeader.hasSuffix(" left"))
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-paused.png")
    }

    @Test func menuPausedShort() throws {
        let longState = AppState.forSnapshot()
        longState.isRecording = true
        longState.pauseManager.pause(for: .seconds(125))
        let headerLong = pausedHeaderText(timeRemaining: longState.pauseManager.formatTimeRemaining())

        let state = AppState.forSnapshot()
        state.isRecording = true
        state.pauseManager.pause(for: .seconds(35))
        let expectedHeader = pausedHeaderText(timeRemaining: state.pauseManager.formatTimeRemaining())
        #expect(expectedHeader.hasPrefix("paused - "))
        #expect(expectedHeader.hasSuffix(" left"))
        #expect(headerLong != expectedHeader)
        let updateController = makeSnapshotUpdateController()
        try render(MenuContent(appState: state, updateController: updateController), size: menuSize, to: "menu-paused-short.png")
    }

    @Test func menuPausedIndefinite() throws {
        let state = AppState.forSnapshot()
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

    @Test func settingsObserverWithSolToggle() throws {
        var config = AppConfig()
        config.solInitiatedChatNotificationsEnabled = true
        let state = AppState.forSnapshot(config: config)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .observer, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-observer-with-sol-toggle.png"
        )
    }

    @Test func settingsServiceEmpty() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .service),
            size: settingsSize,
            to: "settings-service-empty.png"
        )
    }

    @Test func settingsServiceConfigured() throws {
        var config = AppConfig(serverURL: "https://solstone.example.com")
        config.serverKey = "sk-test-key-1234"
        let state = AppState.forSnapshot(config: config)
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .service),
            size: settingsSize,
            to: "settings-service-configured.png"
        )
    }

    @Test func settingsServiceUpgradeFailed() throws {
        let rawMessage = "'observer' moved to 'journal observer' — run that instead."
        let rawLog = """
        uv tool install /bundle/wheelhouse/solstone-\(BundleConfig.solstonePinVersion)-py3-none-macosx_14_0_arm64.whl --find-links /bundle/wheelhouse --no-index --offline
        error: \(rawMessage)
        """
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .failed(.registering(message: rawMessage))
        state.installer.modelsProgress = .done
        state.installer.lastFailureLog = rawLog
        state.installer.upgradeFailureRecord = UpgradeFailureRecord(
            installed: BundleConfig.solstonePinVersion,
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: rawLog
        )
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .service),
            size: settingsSize,
            to: "settings-service-upgrade-failed.png"
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

    @Test func settingsStatusIdle() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        state.uploadCoordinator.status = .synced
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .status),
            size: settingsSize,
            to: "settings-status-idle.png"
        )
    }

    @Test func settingsStatusRecording() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        state.isRecording = true
        state.uploadCoordinator.status = .syncing(checked: 3, total: 10)
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .status),
            size: settingsSize,
            to: "settings-status-recording.png"
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

    @Test func settingsHelp() throws {
        let state = AppState.forSnapshot()
        let updateController = makeSnapshotUpdateController()
        try render(
            SettingsView(appState: state, updateController: updateController, selectedTab: .help),
            size: settingsSize,
            to: "settings-help.png"
        )
    }

    private let aboutSize = CGSize(width: 300, height: 390)

    @Test func about() throws {
        try render(AboutView(), size: aboutSize, to: "about.png")
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
