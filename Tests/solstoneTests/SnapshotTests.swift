// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreAudio
import SwiftUI
import Testing
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
    }

    private enum RenderError: Error {
        case noBitmap
        case noPNG
    }

    private let menuSize = CGSize(width: 250, height: 350)

    @Test func menuIdle() throws {
        let state = AppState.forSnapshot()
        try render(MenuContent(appState: state), size: menuSize, to: "menu-idle.png")
    }

    @Test func menuRecording() throws {
        let state = AppState.forSnapshot()
        state.isRecording = true
        try render(MenuContent(appState: state), size: menuSize, to: "menu-recording.png")
    }

    @Test func menuPaused() throws {
        let state = AppState.forSnapshot()
        state.isRecording = true
        state.pauseManager.pause(for: .indefinite)
        try render(MenuContent(appState: state), size: menuSize, to: "menu-paused.png")
    }

    @Test func menuError() throws {
        let state = AppState.forSnapshot()
        state.errorMessage = "Screen recording permission denied"
        try render(MenuContent(appState: state), size: menuSize, to: "menu-error.png")
    }

    private let settingsSize = CGSize(width: 500, height: 400)

    @Test func settingsObserver() throws {
        let state = AppState.forSnapshot()
        try render(
            SettingsView(appState: state, selectedTab: .observer, initialStorageUsedMB: 42),
            size: settingsSize,
            to: "settings-observer.png"
        )
    }

    @Test func settingsServiceEmpty() throws {
        let state = AppState.forSnapshot()
        try render(
            SettingsView(appState: state, selectedTab: .service),
            size: settingsSize,
            to: "settings-service-empty.png"
        )
    }

    @Test func settingsServiceConfigured() throws {
        var config = AppConfig(serverURL: "https://solstone.example.com")
        config.serverKey = "sk-test-key-1234"
        let state = AppState.forSnapshot(config: config)
        try render(
            SettingsView(appState: state, selectedTab: .service),
            size: settingsSize,
            to: "settings-service-configured.png"
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
            SettingsView(appState: state, selectedTab: .microphones),
            size: settingsSize,
            to: "settings-microphones.png"
        )
    }

    @Test func settingsMicrophonesEmpty() throws {
        let state = AppState.forSnapshot()
        try render(
            SettingsView(appState: state, selectedTab: .microphones),
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
        try render(
            SettingsView(appState: state, selectedTab: .privacy),
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
        try render(
            SettingsView(appState: state, selectedTab: .privacy),
            size: settingsSize,
            to: "settings-privacy-empty.png"
        )
    }

    @Test func settingsStatusIdle() throws {
        let state = AppState.forSnapshot()
        state.uploadCoordinator.status = .synced
        try render(
            SettingsView(appState: state, selectedTab: .status),
            size: settingsSize,
            to: "settings-status-idle.png"
        )
    }

    @Test func settingsStatusRecording() throws {
        let state = AppState.forSnapshot()
        state.isRecording = true
        state.uploadCoordinator.status = .syncing(checked: 3, total: 10)
        try render(
            SettingsView(appState: state, selectedTab: .status),
            size: settingsSize,
            to: "settings-status-recording.png"
        )
    }

    @Test func settingsPermissions() throws {
        let state = AppState.forSnapshot()
        try render(
            SettingsView(appState: state, selectedTab: .permissions),
            size: settingsSize,
            to: "settings-permissions.png"
        )
    }

    private let aboutSize = CGSize(width: 300, height: 390)

    @Test func about() throws {
        try render(AboutView(), size: aboutSize, to: "about.png")
    }
}
