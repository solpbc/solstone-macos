// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import Darwin
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
        bodyURL: URL,
        ioInjector: BrowserIntakeIOInjector
    ) throws -> PreparedIngestV3Upload
    func uploadStaged(prepared: PreparedIngestV3Upload, lease: BrowserUploadLease) async -> UploadResult
}

extension UploadClient: BrowserUploadTransport {
    func prepareUpload(
        serverURL: String,
        day: String,
        segment: String,
        mediaFiles: [URL],
        metadata: [String: IngestJSONValue]?,
        source: String?,
        boundary: String,
        bodyURL: URL,
        ioInjector: BrowserIntakeIOInjector
    ) throws -> PreparedIngestV3Upload {
        try IngestV3UploadRequestBuilder.build(
            baseURL: serverURL,
            day: day,
            segment: segment,
            selectedFiles: mediaFiles,
            meta: metadata,
            source: source,
            boundary: boundary,
            bodyURL: bodyURL,
            ioHooks: .browser(using: ioInjector)
        )
    }
}

extension IngestV3UploadIOHooks {
    static func browser(using injector: BrowserIntakeIOInjector) -> IngestV3UploadIOHooks {
        IngestV3UploadIOHooks(
            beforeRead: { try injector.check(.read) },
            beforeWrite: { try injector.check(.write) },
            beforeSync: { try injector.check(.sync) },
            sync: { handle in
                guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else { throw BrowserIntakeStoreError.localIO }
            }
        )
    }
}

public final class BrowserUploadPlanner: @unchecked Sendable {
    private let store: BrowserIntakeStore
    private let gate: BrowserUploadGate
    private let client: any BrowserUploadTransport
    private let serverURLProvider: @Sendable () async -> String?
    private let syncPausedProvider: @Sendable () async -> Bool
    private let nowMs: @Sendable () -> UInt64
    private let routeState: BrowserIntakeRouteState

    init(
        store: BrowserIntakeStore,
        gate: BrowserUploadGate,
        client: any BrowserUploadTransport,
        serverURLProvider: @escaping @Sendable () async -> String? = { "http://127.0.0.1" },
        syncPausedProvider: @escaping @Sendable () async -> Bool = { false },
        nowMs: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) },
        routeState: BrowserIntakeRouteState = BrowserIntakeRouteState()
    ) {
        self.store = store
        self.gate = gate
        self.client = client
        self.serverURLProvider = serverURLProvider
        self.syncPausedProvider = syncPausedProvider
        self.nowMs = nowMs
        self.routeState = routeState
    }

    public func planAndUpload() async {
        guard !Task.isCancelled, await !syncPausedProvider() else { return }
        guard let serverURL = await serverURLProvider(), let permit = gate.currentPermit(),
              let route = routeState.snapshot(for: permit),
              BrowserOpaqueString.equals(route.serverURL, serverURL) else { return }
        for period in store.getAllFinalizedPeriods() where BrowserOpaqueString.equals(period.generation, permit.generation) {
            guard !Task.isCancelled, await !syncPausedProvider() else { continue }
            guard let day = period.requestedDay, !day.isEmpty,
                  let segment = period.requestedSegment, !segment.isEmpty else {
                guard isCurrent(period: period, lease: nil) else { continue }
                failStorage(period: period, error: BrowserIntakeStoreError.localIO)
                continue
            }
            guard let lease = gate.makeLease(permit: permit, periodId: period.periodId, routeCheck: { [routeState] in routeState.matches(route) }),
                  BrowserOpaqueString.equals(lease.periodId, period.periodId), lease.isValid() else { return }
            await deliver(period: period, lease: lease, serverURL: serverURL, day: day, segment: segment)
            if !lease.isValid() { return }
        }
    }

    private func deliver(
        period: BrowserStoredPeriod,
        lease: BrowserUploadLease,
        serverURL: String,
        day: String,
        segment: String
    ) async {
        let fileURL = store.periodFileURL(for: period.periodId)
        let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: fileURL.deletingLastPathComponent())

        var binding: BrowserIngestAck?
        do {
            try store.validateFinalizedPayload(period)
            binding = try store.storedDeliveryBinding(periodId: period.periodId)
            if binding == nil, let legacyAck = try BrowserIngestAckStore.read(from: ackURL, ioInjector: store.ioInjector) {
                try store.persistDeliveryBinding(legacyAck)
                binding = legacyAck
            }
        } catch {
            if logStaleProof(error, periodId: period.periodId) { return }
            failStorage(period: period, error: error, lease: lease)
            return
        }
        if let binding {
            do {
                if !period.ackDurable || !(store.getPeriod(periodId: period.periodId)?.ackDurable ?? false) {
                    try store.publishDeliveryAck(binding)
                }
                let listing = try await client.getSegmentsDay(serverURL: serverURL, day: day, source: "browser")
                guard isCurrent(period: period, lease: lease) else { return }
                recordDeliveryFailure(nil, period: period, lease: lease)
                if listingMatches(listing, period: period, binding: binding),
                   store.getPeriod(periodId: period.periodId)?.ackDurable == true {
                    guard isCurrent(period: period, lease: lease) else { return }
                    try store.releaseProven(periodId: period.periodId, binding: binding, nowMs: nowMs())
                }
            } catch {
                if logStaleProof(error, periodId: period.periodId) { return }
                Logger.upload.error("Browser delivery reconciliation failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                recordDeliveryFailure("relay_unavailable", period: period, lease: lease)
            }
            return
        }

        guard lease.isValid() else { return }
        let sourceSize: Int
        do {
            try store.validateMutationPath(fileURL)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw BrowserIntakeStoreError.localIO }
            try store.ioInjector.check(.size)
            guard let measured = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int else {
                throw BrowserIntakeStoreError.localIO
            }
            sourceSize = measured
        } catch {
            failStorage(period: period, error: error, lease: lease)
            return
        }
        guard sourceSize > 0, sourceSize == period.committedLength else {
            failStorage(period: period, error: BrowserIntakeStoreError.localIO, lease: lease)
            return
        }

        let stagingDirectory = store.stagingRootURL()
            .appendingPathComponent("browser-upload-\(UUID().uuidString)", isDirectory: true)
        let reservation = sourceSize + 64 * 1024
        do {
            try store.registerStagingDirectory(stagingDirectory, reservedBytes: reservation, generation: period.generation)
        } catch let error as BrowserIntakeStoreError {
            Logger.storage.error("Browser staging reservation failed: \(error.localizedDescription, privacy: .public)")
            recordDeliveryFailure(error == .resourceExhausted ? "resource_exhausted" : "local_io", period: period, lease: lease)
            return
        } catch {
            Logger.storage.error("Browser staging reservation failed: \(error.localizedDescription, privacy: .public)")
            recordDeliveryFailure("local_io", period: period, lease: lease)
            return
        }
        defer {
            do {
                try store.releaseStagingDirectory(stagingDirectory)
            } catch {
                if isCurrent(period: period, lease: lease) {
                    Logger.storage.error("Browser upload staging cleanup failed for period \(period.periodId, privacy: .public)")
                    _ = store.setStoreFailed(true, forGeneration: period.generation)
                } else {
                    Logger.upload.warning("Browser staging cleanup failed for stale period \(period.periodId, privacy: .public)")
                }
            }
        }

        let multipartURL = stagingDirectory.appendingPathComponent("multipart.body")
        do {
            try store.validateMutationPath(stagingDirectory)
            try store.validateMutationPath(multipartURL)
            let prepared = try client.prepareUpload(
                serverURL: serverURL,
                day: day,
                segment: segment,
                mediaFiles: [fileURL],
                metadata: nil,
                source: "browser",
                boundary: UUID().uuidString,
                bodyURL: multipartURL,
                ioInjector: store.ioInjector
            )
            guard let stagedPart = prepared.stagedParts.first,
                  prepared.stagedParts.count == 1,
                  stagedPart.size == UInt64(period.committedLength),
                  BrowserOpaqueString.equals(stagedPart.sha256, period.fileSha256) else {
                failStorage(period: period, error: BrowserIntakeStoreError.localIO, lease: lease)
                return
            }
            guard isCurrent(period: period, lease: lease) else { return }
            let result = await client.uploadStaged(prepared: prepared, lease: lease)
            guard isCurrent(period: period, lease: lease) else { return }

            switch result {
            case .success(let info):
                let response = info.response
                guard response.validate(
                    stagedFiles: prepared.stagedParts,
                    stagedMeta: prepared.metadata,
                    submittedSegment: prepared.submittedSegment
                ), let part = prepared.stagedParts.first else {
                    Logger.upload.error("Browser upload response did not match period \(period.periodId, privacy: .public)")
                    recordDeliveryFailure("journal_rejected", period: period, lease: lease)
                    return
                }
                let ack = BrowserIngestAck(
                    generation: period.generation,
                    source: "browser",
                    periodId: period.periodId,
                    filename: "browser_pages.jsonl",
                    sha256: part.sha256,
                    size: part.size,
                    metadata: prepared.metadata,
                    requestedDay: day,
                    requestedSegment: segment,
                    canonicalKey: response.storedSegmentKey,
                    status: response.status
                )
                try store.publishDeliveryAck(ack)
                recordDeliveryFailure(nil, period: period, lease: lease)
            case .failure(let error):
                if case .segmentScoped(.segmentRemoved) = classifyUpload(error), lease.isValid(),
                   let part = prepared.stagedParts.first {
                    let proof = BrowserIngestAck(
                        generation: period.generation,
                        source: "browser",
                        periodId: period.periodId,
                        filename: "browser_pages.jsonl",
                        sha256: part.sha256,
                        size: part.size,
                        metadata: prepared.metadata,
                        requestedDay: day,
                        requestedSegment: segment,
                        canonicalKey: period.canonicalKey ?? segment,
                        status: .duplicate
                    )
                    guard isCurrent(period: period, lease: lease) else { return }
                    try store.removeProvenSegment(periodId: period.periodId, binding: proof, nowMs: nowMs())
                    return
                }
                let failure = classifyUpload(error)
                Logger.upload.error("Browser upload failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                recordDeliveryFailure(failureCode(for: failure), period: period, lease: lease)
            }
        } catch {
            if logStaleProof(error, periodId: period.periodId) { return }
            Logger.upload.error("Browser upload preparation failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            recordDeliveryFailure(error as? BrowserIntakeStoreError == .resourceExhausted ? "resource_exhausted" : "local_io", period: period, lease: lease)
        }
    }

    private func listingMatches(_ listing: IngestProtocolV3.SegmentsDay, period: BrowserStoredPeriod, binding: BrowserIngestAck) -> Bool {
        guard BrowserOpaqueString.equals(binding.generation, period.generation),
              BrowserOpaqueString.equals(binding.source, "browser"),
              BrowserOpaqueString.equals(binding.periodId, period.periodId),
              BrowserOpaqueString.equals(binding.filename, "browser_pages.jsonl"),
              BrowserOpaqueString.equals(binding.requestedDay, period.requestedDay),
              BrowserOpaqueString.equals(binding.requestedSegment, period.requestedSegment),
              binding.size == UInt64(period.committedLength),
              BrowserOpaqueString.equals(binding.sha256, period.fileSha256),
              BrowserOpaqueString.equals(binding.canonicalKey, period.canonicalKey),
              binding.metadata == nil else { return false }
        return listing.items.contains { item in
            guard BrowserOpaqueString.equals(item.key, binding.canonicalKey) else { return false }
            if let original = item.originalKey, !BrowserOpaqueString.equals(original, binding.requestedSegment) { return false }
            return item.files.contains { file in
                BrowserOpaqueString.equals(file.name, binding.filename)
                    && file.size == binding.size
                    && BrowserOpaqueString.equals(file.sha256, binding.sha256)
                    && file.status == .present
            }
        }
    }

    private func failureCode(for classification: UploadAttemptClass) -> String {
        switch classification {
        case .transport, .deviceScoped(.notServing), .deviceScoped(.revoked):
            return "relay_unavailable"
        case .deviceScoped(.journalRefused), .segmentScoped(.deterministic), .segmentScoped(.receivedNotWritten):
            return "journal_rejected"
        case .segmentScoped(.segmentRemoved):
            return "journal_rejected"
        }
    }

    private func logStaleProof(_ error: Error, periodId: String) -> Bool {
        guard (error as? BrowserIntakeStoreError) == .staleGeneration else { return false }
        Logger.upload.warning("Browser proof publication skipped for stale period \(periodId, privacy: .public)")
        return true
    }

    private func isCurrent(period: BrowserStoredPeriod, lease: BrowserUploadLease?) -> Bool {
        guard lease?.isValid() ?? true,
              let permit = gate.currentPermit(),
              BrowserOpaqueString.equals(permit.generation, period.generation) else {
            Logger.upload.warning("Browser operation skipped for stale period \(period.periodId, privacy: .public)")
            return false
        }
        return true
    }

    private func recordDeliveryFailure(_ failure: String?, period: BrowserStoredPeriod, lease: BrowserUploadLease) {
        guard isCurrent(period: period, lease: lease) else { return }
        if !store.setDeliveryFailure(failure, forGeneration: period.generation) {
            Logger.upload.warning("Browser delivery state skipped for stale period \(period.periodId, privacy: .public)")
        }
    }

    private func failStorage(period: BrowserStoredPeriod, error: Error, lease: BrowserUploadLease? = nil) {
        guard isCurrent(period: period, lease: lease) else { return }
        Logger.storage.error("Browser spool read failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        if !store.setStoreFailed(true, forGeneration: period.generation) {
            Logger.storage.error("Browser storage failure skipped for stale period \(period.periodId, privacy: .public)")
        }
    }
}

#endif
