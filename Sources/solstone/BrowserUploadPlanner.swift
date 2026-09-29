// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import os

protocol BrowserUploadTransport: Sendable {
    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay
    func prepareUpload(
        serverURL: String,
        day: String,
        segment: String,
        mediaFiles: [URL],
        metadata: [String: IngestJSONValue]?,
        source: String?,
        boundary: String,
        bodyURL: URL
    ) throws -> PreparedIngestV3Upload
    func uploadStaged(prepared: PreparedIngestV3Upload) async -> UploadResult
}

extension UploadClient: BrowserUploadTransport {}

public final class BrowserUploadPlanner: @unchecked Sendable {
    private let store: BrowserIntakeStore
    private let gate: BrowserUploadGate
    private let client: any BrowserUploadTransport
    private let serverURLProvider: @Sendable () async -> String?
    private let syncPausedProvider: @Sendable () async -> Bool

    init(
        store: BrowserIntakeStore,
        gate: BrowserUploadGate,
        client: any BrowserUploadTransport,
        serverURLProvider: @escaping @Sendable () async -> String? = { "http://127.0.0.1" },
        syncPausedProvider: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.store = store
        self.gate = gate
        self.client = client
        self.serverURLProvider = serverURLProvider
        self.syncPausedProvider = syncPausedProvider
    }

    public func planAndUpload() async {
        guard await !syncPausedProvider() else { return }
        guard let serverURL = await serverURLProvider() else { return }
        guard let permit = gate.currentPermit() else { return }

        let periods = store.getAllFinalizedPeriods().filter { $0.generation == permit.generation }
        for period in periods {
            guard let day = period.requestedDay, !day.isEmpty,
                  let segment = period.requestedSegment, !segment.isEmpty else {
                continue
            }
            let fileURL = store.periodFileURL(for: period.periodId)
            let periodDir = fileURL.deletingLastPathComponent()
            let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: periodDir)
            let existingAck = BrowserIngestAckStore.read(from: ackURL)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                continue
            }
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            guard fileSize > 0 else {
                continue
            }

            do {
                let dayListing = try await client.getSegmentsDay(serverURL: serverURL, day: day, source: "browser")
                if let item = dayListing.items.first(where: { $0.key == segment }),
                   let fileItem = item.files.first(where: { $0.name == "browser_pages.jsonl" }),
                   fileItem.status == .present,
                   let ack = existingAck,
                   ack.sha256 == fileItem.sha256,
                   ack.sha256 == period.fileSha256 {
                    store.releaseProven(periodId: period.periodId)
                    continue
                }
            } catch {
                Logger.upload.debug("Browser day listing check failed for day \(day, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            if existingAck != nil {
                continue
            }

            guard gate.enterBodyRead(permit: permit) else {
                return
            }
            await sendHeldBody(
                fileURL: fileURL,
                permit: permit,
                serverURL: serverURL,
                day: day,
                segment: segment,
                period: period,
                ackURL: ackURL
            )
        }
    }

    private func sendHeldBody(
        fileURL: URL,
        permit: BrowserUploadPermit,
        serverURL: String,
        day: String,
        segment: String,
        period: BrowserStoredPeriod,
        ackURL: URL
    ) async {
        defer { gate.leaveBodyRead() }
        let bodyData = (try? Data(contentsOf: fileURL)) ?? Data()
        guard !bodyData.isEmpty, gate.isPermitActive(permit) else {
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-upload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pageURL = tempDir.appendingPathComponent("browser_pages.jsonl")
        let multipartURL = tempDir.appendingPathComponent("multipart.body")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try bodyData.write(to: pageURL)
            let prepared = try client.prepareUpload(
                serverURL: serverURL,
                day: day,
                segment: segment,
                mediaFiles: [pageURL],
                metadata: nil,
                source: "browser",
                boundary: UUID().uuidString,
                bodyURL: multipartURL
            )
            let result = await client.uploadStaged(prepared: prepared)
            switch result {
            case .success(let info):
                let response = info.response
                guard response.validate(
                    stagedFiles: prepared.stagedParts,
                    stagedMeta: prepared.metadata,
                    submittedSegment: prepared.submittedSegment
                ) else {
                    Logger.upload.error("Browser upload response did not match the staged period \(period.periodId, privacy: .public)")
                    return
                }
                guard let part = prepared.stagedParts.first else { return }
                let ack = BrowserIngestAck(
                    generation: period.generation,
                    source: "browser",
                    periodId: period.periodId,
                    filename: "browser_pages.jsonl",
                    sha256: part.sha256,
                    size: part.size,
                    metadata: nil,
                    requestedDay: day,
                    requestedSegment: segment,
                    canonicalKey: response.storedSegmentKey,
                    status: response.status
                )
                try BrowserIngestAckStore.write(ack, to: ackURL)
                store.recordDelivered(periodId: period.periodId, canonicalKey: response.storedSegmentKey)
            case .failure(let error):
                Logger.upload.error("Browser upload failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            Logger.upload.error("Browser upload preparation failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func handleSegmentRemoved(generation: String, source: String, periodId: String) {
        guard source == "browser" else { return }
        store.removeSegmentPeriod(generation: generation, periodId: periodId)
    }
}

#endif
