// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import os

/// The journal side of terminal delivery. A protocol so tests run without a network.
protocol TerminalUploadTransport: Sendable {
    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay
    func prepareTerminalUpload(
        serverURL: String,
        segment: TerminalSpoolSegment,
        bodyURL: URL
    ) throws -> PreparedIngestV3Upload
    func uploadStaged(prepared: PreparedIngestV3Upload) async -> UploadResult
}

extension UploadClient: TerminalUploadTransport {
    func prepareTerminalUpload(
        serverURL: String,
        segment: TerminalSpoolSegment,
        bodyURL: URL
    ) throws -> PreparedIngestV3Upload {
        try prepareUpload(
            serverURL: serverURL,
            day: segment.day,
            segment: segment.segment,
            mediaFiles: segment.files,
            metadata: segment.zone,
            source: TerminalUploadPlanner.source,
            bodyURL: bodyURL
        )
    }
}

/// Delivers finished terminal segments over this app's own connection. A segment
/// leaves the spool only once the journal has answered for every file in it.
actor TerminalUploadPlanner {
    static let source = "tmux"
    private static let refusedRetrySeconds: TimeInterval = 3600

    private let root: URL
    private let transport: any TerminalUploadTransport
    private let serverURL: @Sendable () async -> String?
    private let isHeld: @Sendable () async -> Bool
    private let activity: @Sendable (Bool) async -> Void
    private let reportDelivery: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private var refusedUntil: [String: Date] = [:]
    private var running = false
    private var rerun = false

    init(
        root: URL,
        transport: any TerminalUploadTransport,
        serverURL: @escaping @Sendable () async -> String?,
        isHeld: @escaping @Sendable () async -> Bool,
        activity: @escaping @Sendable (Bool) async -> Void = { _ in },
        reportDelivery: @escaping @Sendable () async -> Void = {},
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.root = root
        self.transport = transport
        self.serverURL = serverURL
        self.isHeld = isHeld
        self.activity = activity
        self.reportDelivery = reportDelivery
        self.now = now
    }

    /// Runs one pass, or asks the running one to go again when it ends.
    func planAndUpload() async {
        guard !running else {
            rerun = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            await pass()
        } while rerun
    }

    private func pass() async {
        guard await !isHeld(), let serverURL = await serverURL() else { return }
        let segments = TerminalSpool.finished(root: root)
        guard !segments.isEmpty else { return }
        var listings: [String: IngestProtocolV3.SegmentsDay] = [:]
        for segment in segments {
            guard !Task.isCancelled, await !isHeld() else { return }
            if let until = refusedUntil[segment.directory.path], until > now() { continue }
            let listing: IngestProtocolV3.SegmentsDay
            if let known = listings[segment.day] {
                listing = known
            } else {
                do {
                    listing = try await transport.getSegmentsDay(
                        serverURL: serverURL,
                        day: segment.day,
                        source: Self.source
                    )
                    listings[segment.day] = listing
                } catch {
                    Logger.upload.error("Terminal day listing failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
            if Self.journalHoldsAll(of: segment, in: listing) {
                remove(segment)
                continue
            }
            guard await deliver(segment, serverURL: serverURL) else { return }
        }
    }

    /// Only one listed row that accounts for every file here, byte for byte, may
    /// stand in for sending it.
    static func journalHoldsAll(of segment: TerminalSpoolSegment, in listing: IngestProtocolV3.SegmentsDay) -> Bool {
        let rows = listing.items.filter { $0.segment == segment.segment || $0.key == segment.segment }
        guard rows.count == 1, let row = rows.first else { return false }
        for file in segment.files {
            let matches = row.files.filter { $0.effectiveName == file.lastPathComponent }
            guard matches.count == 1, let remote = matches.first, remote.status.provesHold,
                  let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber,
                  remote.size == size.uint64Value,
                  let digest = sha256(file), digest.caseInsensitiveCompare(remote.sha256) == .orderedSame
            else { return false }
        }
        return true
    }

    private static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func remove(_ segment: TerminalSpoolSegment) {
        do {
            try TerminalSpool.remove(segment)
        } catch {
            Logger.storage.error("Terminal segment not removed: \(error.localizedDescription, privacy: .public)")
        }
        refusedUntil[segment.directory.path] = nil
    }

    /// `false` ends the pass.
    private func deliver(_ segment: TerminalSpoolSegment, serverURL: String) async -> Bool {
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        let bodyURL = staging.appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let prepared: PreparedIngestV3Upload
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            prepared = try transport.prepareTerminalUpload(serverURL: serverURL, segment: segment, bodyURL: bodyURL)
        } catch {
            Logger.upload.error("Terminal upload not prepared: \(error.localizedDescription, privacy: .public)")
            refusedUntil[segment.directory.path] = now().addingTimeInterval(Self.refusedRetrySeconds)
            return true
        }
        await activity(true)
        let result = await transport.uploadStaged(prepared: prepared)
        await activity(false)
        switch result {
        case .success:
            remove(segment)
            await reportDelivery()
            return true
        case .failure(let error):
            switch classifyUpload(error) {
            case .segmentScoped(.segmentRemoved):
                // The owner removed this from the journal; sending it again would undo that.
                remove(segment)
                return true
            case .segmentScoped:
                refusedUntil[segment.directory.path] = now().addingTimeInterval(Self.refusedRetrySeconds)
                Logger.upload.error("Terminal segment refused: \(error.localizedDescription, privacy: .public)")
                return true
            case .transport, .deviceScoped:
                Logger.upload.error("Terminal upload failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }
}
