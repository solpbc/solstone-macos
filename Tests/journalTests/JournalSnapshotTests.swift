// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import JournalMarkKit
import JournalRuntime
import JournalRuntimeTestSupport
import SwiftUI
import Testing
@testable import journal

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

@Suite("Snapshot-journal")
@MainActor
struct JournalSnapshotTests {
    private static nonisolated(unsafe) var _outputDir: URL?
    private let size = CGSize(width: 800, height: 560)

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
        JournalMarkFont.register()
    }

    @Test func paneMatrix() async throws {
        try await renderHomeConfiguredRunning()
        try await renderHomeConfiguredStopped()
        try renderHomeUnconfiguredInterim()
        try renderHomeHostnameFallback()
        try renderJournalNameAndDiskUsage()
        try await renderRunStateRunning()
        try renderRunStateStopped()
        try await renderRunStateBlocked()
        try await renderRunStateUnknownHealth()
        try renderBackupStatic()
        try renderStartup(enabled: true)
        try renderStartup(enabled: false)
    }

    private func renderHomeConfiguredRunning() async throws {
        let supervisor = try await runningSupervisor()
        let model = try configuredModel(supervisor: supervisor, mark: .uiTestSample, name: "home base")
        model.selectedPane = .home
        try renderWindow(model, to: "journal-home-configured-running.png")
    }

    private func renderHomeConfiguredStopped() async throws {
        let fixture = try makeConfiguredFixture()
        let supervisor = JournalSupervisor()
        supervisor.applyRuntimeStatus(.stoppedByUser)
        let model = configuredModel(fixture: fixture, supervisor: supervisor, mark: .uiTestSample, name: "home base")
        model.selectedPane = .home
        try renderWindow(model, to: "journal-home-configured-stopped.png")
    }

    private func renderHomeUnconfiguredInterim() throws {
        let model = unconfiguredModel()
        model.selectedPane = .home
        try renderWindow(model, to: "journal-home-unconfigured-interim.png")
    }

    private func renderHomeHostnameFallback() throws {
        let model = try configuredModel(mark: nil, name: "", machineName: "machine-name")
        model.selectedPane = .home
        try renderWindow(model, to: "journal-home-hostname-fallback.png")
    }

    private func renderJournalNameAndDiskUsage() throws {
        let model = try configuredModel(mark: .uiTestSample, name: "home base")
        model.selectedPane = .journal
        model.diskUsageBytes = 1_234_567
        try renderWindow(model, to: "journal-journal-name-diskusage.png")
    }

    private func renderRunStateRunning() async throws {
        let supervisor = try await runningSupervisor()
        let model = try configuredModel(supervisor: supervisor, mark: .uiTestSample, name: "home base")
        model.selectedPane = .runState
        model.healthDisplay = .healthy
        model.runtimeVersion = "1.2.3"
        try renderWindow(model, to: "journal-run-state-running.png")
    }

    private func renderRunStateStopped() throws {
        let fixture = try makeConfiguredFixture()
        let supervisor = JournalSupervisor()
        supervisor.applyRuntimeStatus(.stoppedByUser)
        let model = configuredModel(fixture: fixture, supervisor: supervisor, mark: .uiTestSample, name: "home base")
        model.selectedPane = .runState
        model.healthDisplay = .stopped
        model.runtimeVersion = "unknown"
        try renderWindow(model, to: "journal-run-state-stopped.png")
    }

    private func renderRunStateBlocked() async throws {
        let diagnostic = JournalDiagnostic(commandLabel: "gate", outputExcerpt: "port busy")
        let supervisor = JournalSupervisor(
            gate: MockSingleSupervisorGate(result: .blocked(.portConflict(diagnostic))),
            materializer: MockRuntimeMaterializer(result: .success(try makeRuntime())),
            runner: MockSupervisedChildRunner(),
            readinessGate: MockJournalReadinessGate(result: .ready)
        )
        let fixture = try makeConfiguredFixture()
        _ = await supervisor.start(journalRoot: try #require(fixture.config.journalRoot))
        let model = configuredModel(fixture: fixture, supervisor: supervisor, mark: .uiTestSample, name: "home base")
        model.selectedPane = .runState
        try renderWindow(model, to: "journal-run-state-blocked.png")
    }

    private func renderRunStateUnknownHealth() async throws {
        let supervisor = try await runningSupervisor()
        let model = try configuredModel(supervisor: supervisor, mark: .uiTestSample, name: "home base")
        model.selectedPane = .runState
        model.healthDisplay = .unknown
        model.runtimeVersion = "unknown"
        try renderWindow(model, to: "journal-run-state-unknown-health.png")
    }

    private func renderBackupStatic() throws {
        let model = try configuredModel(mark: .uiTestSample, name: "home base")
        model.selectedPane = .backup
        try renderWindow(model, to: "journal-backup-static.png")
    }

    private func renderStartup(enabled: Bool) throws {
        let fixture = try makeConfiguredFixture()
        fixture.config.setLaunchAtLoginEnabled(enabled)
        let model = configuredModel(fixture: fixture, supervisor: JournalSupervisor(), mark: .uiTestSample, name: "home base")
        model.selectedPane = .startup
        try renderWindow(model, to: enabled ? "journal-startup-enabled.png" : "journal-startup-disabled.png")
    }

    private func runningSupervisor() async throws -> JournalSupervisor {
        let supervisor = JournalSupervisor(
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(try makeRuntime())),
            runner: MockSupervisedChildRunner(),
            readinessGate: MockJournalReadinessGate(result: .ready)
        )
        let root = try makeTemporaryDirectory()
        _ = await supervisor.start(journalRoot: root)
        supervisor.applyRuntimeStatus(.running)
        return supervisor
    }

    private func configuredModel(
        supervisor: JournalSupervisor = JournalSupervisor(),
        mark: JournalMark?,
        name: String,
        machineName: String = "machine-name"
    ) throws -> JournalWindowModel {
        configuredModel(
            fixture: try makeConfiguredFixture(),
            supervisor: supervisor,
            mark: mark,
            name: name,
            machineName: machineName
        )
    }

    private func configuredModel(
        fixture: SnapshotFixture,
        supervisor: JournalSupervisor,
        mark: JournalMark?,
        name: String,
        machineName: String = "machine-name"
    ) -> JournalWindowModel {
        let model = JournalWindowModel(
            config: fixture.config,
            supervisor: supervisor,
            fetchConfig: { JournalConfig(journal: JournalConfigSection(name: name)) },
            updateName: { JournalConfig(journal: JournalConfigSection(name: $0)) },
            fetchIdentity: { _ in mark },
            fetchDiskUsage: { _ in 1_234_567 },
            fetchHealth: { _, _ in .unknown(JournalDiagnostic(commandLabel: "health")) },
            fetchVersion: { _, _ in nil },
            machineNameProvider: { machineName },
            appVersion: "9.8.7"
        )
        model.identityMark = mark
        model.journalName = name
        model.draftJournalName = name
        return model
    }

    private func unconfiguredModel() -> JournalWindowModel {
        let fixture = makeUnconfiguredFixture()
        return JournalWindowModel(
            config: fixture.config,
            supervisor: JournalSupervisor(),
            fetchConfig: { JournalConfig(journal: JournalConfigSection(name: "")) },
            updateName: { JournalConfig(journal: JournalConfigSection(name: $0)) },
            fetchIdentity: { _ in nil },
            fetchDiskUsage: { _ in 0 },
            fetchHealth: { _, _ in .unknown(JournalDiagnostic(commandLabel: "health")) },
            fetchVersion: { _, _ in nil },
            machineNameProvider: { "machine-name" },
            appVersion: "9.8.7"
        )
    }

    private func makeConfiguredFixture() throws -> SnapshotFixture {
        let fixture = makeUnconfiguredFixture()
        let root = try makeTemporaryDirectory()
        fixture.config.journalRoot = root
        return fixture
    }

    private func makeUnconfiguredFixture() -> SnapshotFixture {
        let suiteName = "app.solstone.journal.snapshots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let config = JournalAppConfig(defaults: defaults, loginItemManager: SnapshotFakeLoginItemManager())
        return SnapshotFixture(suiteName: suiteName, defaults: defaults, config: config)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func renderWindow(_ model: JournalWindowModel, to filename: String) throws {
        try render(
            JournalSettingsWindow(model: model, openURL: { _ in })
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: size,
            to: filename
        )
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
        guard bytesPerPixel >= 3, width > 0, height > 0 else { return }

        let backgroundPixel = bitmapData
        let epsilon = 8
        let minimumContentPixels = 400
        var contentPixelCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bitmapData.advanced(by: y * bytesPerRow + x * bytesPerPixel)
                if abs(Int(pixel[0]) - Int(backgroundPixel[0])) > epsilon ||
                    abs(Int(pixel[1]) - Int(backgroundPixel[1])) > epsilon ||
                    abs(Int(pixel[2]) - Int(backgroundPixel[2])) > epsilon {
                    contentPixelCount += 1
                }
            }
        }
        if contentPixelCount < minimumContentPixels {
            throw RenderError.emptyContent(
                filename: filename,
                contentPixelCount: contentPixelCount,
                minimum: minimumContentPixels
            )
        }
    }

    private enum RenderError: Error, CustomStringConvertible {
        case noBitmap
        case noPNG
        case emptyContent(filename: String, contentPixelCount: Int, minimum: Int)

        var description: String {
            switch self {
            case .noBitmap: return "failed to create bitmap rep"
            case .noPNG: return "failed to encode PNG"
            case let .emptyContent(filename, contentPixelCount, minimum):
                return "\(filename): \(contentPixelCount) content pixels below \(minimum) minimum"
            }
        }
    }
}

private struct SnapshotFixture {
    let suiteName: String
    let defaults: UserDefaults
    let config: JournalAppConfig
}

@MainActor
private final class SnapshotFakeLoginItemManager: LoginItemManaging {
    func register() throws {}
    func unregister() throws {}
}
