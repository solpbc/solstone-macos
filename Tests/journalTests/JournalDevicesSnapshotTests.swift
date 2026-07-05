// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import JournalMarkKit
import SwiftUI
import Testing
@testable import journal

private func runDevicesSnapshotGit(_ args: String...) throws -> String {
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

private func makeDevicesSnapshotOutputDir() throws -> URL {
    let repoRoot = try runDevicesSnapshotGit("rev-parse", "--show-toplevel")
    let gitHash = try runDevicesSnapshotGit("rev-parse", "--short", "HEAD")

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

@Suite("JournalDevicesSnapshot")
@MainActor
struct JournalDevicesSnapshotTests {
    private static nonisolated(unsafe) var _outputDir: URL?
    private let paneSize = CGSize(width: 560, height: 520)
    private let sheetSize = CGSize(width: 460, height: 560)

    private var outputDir: URL {
        get throws {
            if let dir = Self._outputDir { return dir }
            let dir = try makeDevicesSnapshotOutputDir()
            Self._outputDir = dir
            return dir
        }
    }

    init() {
        _ = NSApplication.shared
        JournalMarkFont.register()
    }

    @Test func paneMatrix() async throws {
        try renderDevicesList()
        try renderDevicesEmpty()
        try renderDevicesNotRunning()
        try renderDevicesNotReady()
        try renderPairingOpen()
        try renderPairingPairedDismissed()
        try renderPairingExpired()
    }

    private func renderDevicesList() throws {
        let model = paneModel(
            state: .loaded,
            devices: [
                DeviceRow(
                    displayLabel: "iphone",
                    role: "phone",
                    network: "local",
                    fingerprint: "phone-a"
                ),
                DeviceRow(
                    displayLabel: "kitchen journal",
                    role: "peer",
                    fingerprint: "peer-a"
                ),
            ]
        )
        try renderPane(model, to: "journal-devices-list.png")
    }

    private func renderDevicesEmpty() throws {
        let model = paneModel(state: .empty)
        try renderPane(model, to: "journal-devices-empty.png")
    }

    private func renderDevicesNotRunning() throws {
        let model = paneModel(state: .notRunning)
        try renderPane(model, to: "journal-devices-not-running.png")
    }

    private func renderDevicesNotReady() throws {
        let model = paneModel(state: .notReady)
        model.loadErrorDetail = "pairing routes are still starting"
        try renderPane(model, to: "journal-devices-not-ready.png")
    }

    private func renderPairingOpen() throws {
        let model = pairingModel()
        let link = "https://journal.example/pair/abc123"
        model.pairingNow = .seconds(40)
        model.pairingState = .open(
            link: link,
            qr: try JournalQRImage.make(from: link),
            deadline: .seconds(125),
            nonce: "nonce-a"
        )
        try renderSheet(model, to: "journal-devices-pairing-open.png")
    }

    private func renderPairingPairedDismissed() throws {
        let model = paneModel(
            state: .loaded,
            devices: [
                DeviceRow(
                    displayLabel: "new device",
                    role: "phone",
                    network: "local",
                    fingerprint: "new-phone"
                ),
            ]
        )
        model.pairingState = .paired
        model.isPairingPresented = false
        try renderPane(model, to: "journal-devices-pairing-paired-dismissed.png")
    }

    private func renderPairingExpired() throws {
        let model = pairingModel()
        model.pairingState = .expired(previousLink: "https://journal.example/pair/expired")
        try renderSheet(model, to: "journal-devices-pairing-expired.png")
    }

    private func paneModel(
        state: JournalDevicesLoadState,
        devices: [DeviceRow] = []
    ) -> JournalDevicesModel {
        let model = JournalDevicesModel(client: SnapshotDevicesClient(devices: devices), copyToClipboard: { _ in })
        model.devices = devices
        model.loadState = state
        for row in devices {
            model.draftLabels[row.fingerprint] = model.displayName(for: row)
        }
        return model
    }

    private func pairingModel() -> JournalDevicesModel {
        let model = JournalDevicesModel(client: SnapshotDevicesClient(devices: []), copyToClipboard: { _ in })
        model.isPairingPresented = true
        return model
    }

    private func renderPane(_ model: JournalDevicesModel, to filename: String) throws {
        try render(
            JournalDevicesPane(model: model)
                .frame(width: paneSize.width, height: paneSize.height)
                .padding(24)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: paneSize,
            to: filename
        )
    }

    private func renderSheet(_ model: JournalDevicesModel, to filename: String) throws {
        try render(
            JournalPairingWindow(model: model)
                .frame(width: sheetSize.width, height: sheetSize.height)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: sheetSize,
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

private struct SnapshotDevicesClient: JournalDevicesClientProtocol {
    let devices: [DeviceRow]

    func listDevices() async throws -> [DeviceRow] {
        devices
    }

    func startPairing() async throws -> PairStartResponse {
        throw JournalDevicesClientError.serverStatus(599)
    }

    func nonceStatus(nonce: String) async throws -> NonceStatusResponse {
        throw JournalDevicesClientError.serverStatus(599)
    }

    func renameDevice(fingerprint: String, label: String) async throws {
        throw JournalDevicesClientError.serverStatus(599)
    }

    func unpairDevice(fingerprint: String) async throws -> UnpairResponse {
        throw JournalDevicesClientError.serverStatus(599)
    }
}
