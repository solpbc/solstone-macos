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

typealias BrowserAdmissionCommit = @Sendable (
    BrowserIntakeRouteCapability,
    @Sendable () throws -> Bool
) throws -> Bool

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
    private struct DeliveryCapture: Sendable {
        let permit: BrowserUploadPermit
        let route: BrowserIntakeRouteCapability
        let client: any BrowserUploadTransport
        let serverURL: String
        let destinationGeneration: String?
    }

    private let store: BrowserIntakeStore
    private let gate: BrowserUploadGate
    private let client: any BrowserUploadTransport
    private let serverURLProvider: @Sendable () async -> String?
    private let syncPausedProvider: @Sendable () async -> Bool
    private let nowMs: @Sendable () -> UInt64
    private let routeState: BrowserIntakeRouteState
    private let admissionLock = NSLock()
    private var carriedPairingAdmissionOpen: @Sendable () -> Bool = { true }
    private var carriedPairingAdmissionCommit: BrowserAdmissionCommit = { _, operation in try operation() }
    private var beforeCustodyCommit: @Sendable () async -> Void = {}

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

    func setCarriedPairingAdmissionOpen(_ predicate: @escaping @Sendable () -> Bool) {
        admissionLock.withLock { carriedPairingAdmissionOpen = predicate }
    }

    func setCarriedPairingAdmissionCommit(_ commit: @escaping BrowserAdmissionCommit) {
        admissionLock.withLock { carriedPairingAdmissionCommit = commit }
    }

    func setBeforeCustodyCommit(_ action: @escaping @Sendable () async -> Void) {
        admissionLock.withLock { beforeCustodyCommit = action }
    }

    private func isCarriedPairingAdmissionOpen() -> Bool {
        let predicate = admissionLock.withLock { carriedPairingAdmissionOpen }
        return predicate()
    }

    public func planAndUpload() async {
        guard !Task.isCancelled, isCarriedPairingAdmissionOpen(), await !syncPausedProvider() else { return }
        guard let serverURL = await serverURLProvider(), let permit = gate.currentPermit(),
              let route = routeState.snapshot(for: permit),
              BrowserOpaqueString.equals(route.serverURL, serverURL) else { return }
        let capture = DeliveryCapture(
            permit: permit,
            route: route,
            client: client,
            serverURL: serverURL,
            destinationGeneration: store.getDestinationGeneration()
        )
        for period in store.getAllFinalizedPeriods() {
            guard !Task.isCancelled, isCarriedPairingAdmissionOpen(), await !syncPausedProvider() else { continue }
            guard isCurrent(period: period, capture: capture, lease: nil) else { return }
            guard let day = period.requestedDay, !day.isEmpty,
                  let segment = period.requestedSegment, !segment.isEmpty else {
                failStorage(period: period, error: BrowserIntakeStoreError.localIO, capture: capture)
                continue
            }
            guard let lease = gate.makeLease(permit: permit, periodId: period.periodId, routeCheck: { [routeState] in routeState.matches(route) }),
                  BrowserOpaqueString.equals(lease.periodId, period.periodId), lease.isValid() else { return }
            await deliver(period: period, lease: lease, capture: capture, day: day, segment: segment)
            guard isCurrent(period: period, capture: capture, lease: nil) else { return }
        }
    }

    private func deliver(
        period: BrowserStoredPeriod,
        lease: BrowserUploadLease,
        capture: DeliveryCapture,
        day: String,
        segment: String
    ) async {
        let fileURL = store.periodFileURL(for: period.periodId)
        let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: fileURL.deletingLastPathComponent())

        var binding: BrowserDeliveryBinding?
        do {
            try store.validateFinalizedPayload(period)
            binding = try store.storedDeliveryBinding(periodId: period.periodId)
        } catch {
            failStorage(period: period, error: error, capture: capture, lease: lease)
            return
        }

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
            failStorage(period: period, error: error, capture: capture, lease: lease)
            return
        }
        guard sourceSize > 0, sourceSize == period.committedLength else {
            failStorage(period: period, error: BrowserIntakeStoreError.localIO, capture: capture, lease: lease)
            return
        }

        let stagingDirectory = store.stagingRootURL()
            .appendingPathComponent("browser-upload-\(UUID().uuidString)", isDirectory: true)
        let reservation = sourceSize + 64 * 1024
        do {
            try store.registerStagingDirectory(stagingDirectory, reservedBytes: reservation, periodId: period.periodId)
        } catch let error as BrowserIntakeStoreError {
            Logger.storage.error("Browser staging reservation failed: \(error.localizedDescription, privacy: .public)")
            recordDeliveryFailure(error == .resourceExhausted ? "resource_exhausted" : "local_io", period: period, capture: capture, lease: lease)
            return
        } catch {
            Logger.storage.error("Browser staging reservation failed: \(error.localizedDescription, privacy: .public)")
            recordDeliveryFailure("local_io", period: period, capture: capture, lease: lease)
            return
        }
        defer {
            do {
                try store.releaseStagingDirectory(stagingDirectory)
            } catch {
                Logger.storage.error("Browser upload staging cleanup failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        guard isCarriedPairingAdmissionOpen() else { return }
        if let binding, binding.namesSameConnection(as: capture.route) {
            do {
                let storedAck = try BrowserIngestAckStore.read(from: ackURL, ioInjector: store.ioInjector)
                if !period.ackDurable || !(store.getPeriod(periodId: period.periodId)?.ackDurable ?? false)
                    || storedAck != binding.ack {
                    try store.publishDeliveryAck(binding)
                }
                let listing = try await capture.client.getSegmentsDay(serverURL: capture.serverURL, day: day, source: "browser")
                guard isCarriedPairingAdmissionOpen(), lease.isValid() else { return }
                if let matched = listingMatch(listing, period: period, ack: binding.ack,
                    destinationGeneration: capture.destinationGeneration),
                   routeState.matches(capture.route),
                   store.getPeriod(periodId: period.periodId)?.ackDurable == true {
                    let updated = BrowserDeliveryBinding(ack: binding.ack.updatingListingCoordinates(from: matched), route: capture.route)
                    let beforeCommit = admissionLock.withLock { beforeCustodyCommit }
                    await beforeCommit()
                    let commit = admissionLock.withLock { carriedPairingAdmissionCommit }
                    let released = try commit(capture.route) { [store, routeState, nowMs] in
                        guard routeState.matches(capture.route) else { return false }
                        if updated != binding { try store.publishDeliveryAck(updated) }
                        guard routeState.matches(capture.route) else { return false }
                        try store.releaseProven(periodId: period.periodId, binding: updated, nowMs: nowMs())
                        return true
                    }
                    guard released else { return }
                    recordDeliveryFailure(nil, period: period, capture: capture, lease: lease)
                    return
                }
            } catch {
                if store.getPeriod(periodId: period.periodId)?.state == "discarded" {
                    Logger.upload.error("Browser delivery reconciliation stopped for discarded period \(period.periodId, privacy: .public)")
                    return
                }
                Logger.upload.error("Browser delivery reconciliation failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                recordDeliveryFailure("relay_unavailable", period: period, capture: capture, lease: lease)
                return
            }
        }

        guard isCarriedPairingAdmissionOpen(), lease.isValid() else { return }
        let multipartURL = stagingDirectory.appendingPathComponent("multipart.body")
        do {
            try store.validateMutationPath(stagingDirectory)
            try store.validateMutationPath(multipartURL)
            let prepared = try capture.client.prepareUpload(
                serverURL: capture.serverURL,
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
                failStorage(period: period, error: BrowserIntakeStoreError.localIO, capture: capture, lease: lease)
                return
            }
            guard isCarriedPairingAdmissionOpen(), lease.isValid() else { return }
            let result = await capture.client.uploadStaged(prepared: prepared, lease: lease)
            guard isCarriedPairingAdmissionOpen(), lease.isValid() else { return }

            switch result {
            case .success(let info):
                let response = info.response
                guard response.validate(
                    stagedFiles: prepared.stagedParts,
                    stagedMeta: prepared.metadata,
                    submittedSegment: prepared.submittedSegment
                ), let part = prepared.stagedParts.first else {
                    Logger.upload.error("Browser upload response did not match period \(period.periodId, privacy: .public)")
                    recordDeliveryFailure("journal_rejected", period: period, capture: capture, lease: lease)
                    return
                }
                let ack = BrowserIngestAck(
                    generation: capture.destinationGeneration ?? "",
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
                let binding = BrowserDeliveryBinding(ack: ack, route: capture.route)
                // An answer that arrives after its route was replaced binds no receipt
                // and releases nothing; the bytes stay held for the current route.
                guard routeState.matches(capture.route) else {
                    Logger.upload.notice("Browser upload answer for period \(period.periodId, privacy: .public) arrived on a replaced route; bytes held")
                    return
                }
                try store.publishDeliveryAck(binding)
                // A collision response gives an opaque key but no stream.
                // Hold the payload until a listing supplies physical coordinates.
                guard response.status != .collision else {
                    recordDeliveryFailure(nil, period: period, capture: capture, lease: lease)
                    return
                }
                let commit = admissionLock.withLock { carriedPairingAdmissionCommit }
                let released = try commit(capture.route) { [store, routeState, nowMs] in
                    guard routeState.matches(capture.route) else { return false }
                    try store.releaseProven(periodId: period.periodId, binding: binding, nowMs: nowMs())
                    return true
                }
                guard released else {
                    Logger.upload.notice("Browser custody release skipped for period \(period.periodId, privacy: .public): route replaced or admission closed; receipt kept")
                    return
                }
                recordDeliveryFailure(nil, period: period, capture: capture, lease: lease)
            case .failure(let error):
                if case .segmentScoped(.segmentRemoved) = classifyUpload(error), lease.isValid(),
                   let part = prepared.stagedParts.first {
                    // The owner removed this segment from the journal; resending it would
                    // resurrect what they deleted. Record the proof and drop the local copy
                    // through the same admitted connection that received the answer.
                    let proof = BrowserIngestAck(
                        generation: capture.destinationGeneration ?? "",
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
                    let proofBinding = BrowserDeliveryBinding(ack: proof, route: capture.route)
                    let commit = admissionLock.withLock { carriedPairingAdmissionCommit }
                    _ = try commit(capture.route) { [store, routeState, nowMs] in
                        guard routeState.matches(capture.route) else { return false }
                        try store.removeProvenSegment(periodId: period.periodId, binding: proofBinding, nowMs: nowMs())
                        return true
                    }
                    return
                }
                let failure = classifyUpload(error)
                Logger.upload.error("Browser upload failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                recordDeliveryFailure(failureCode(for: failure), period: period, capture: capture, lease: lease)
            }
        } catch {
            Logger.upload.error("Browser upload preparation failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            recordDeliveryFailure(error as? BrowserIntakeStoreError == .resourceExhausted ? "resource_exhausted" : "local_io", period: period, capture: capture, lease: lease)
        }
    }

    private func listingMatch(
        _ listing: IngestProtocolV3.SegmentsDay,
        period: BrowserStoredPeriod,
        ack: BrowserIngestAck,
        destinationGeneration: String?
    ) -> IngestProtocolV3.SegmentsItem? {
        guard BrowserOpaqueString.equals(ack.source, "browser"),
              let destinationGeneration,
              BrowserOpaqueString.equals(ack.generation, destinationGeneration),
              BrowserOpaqueString.equals(ack.periodId, period.periodId),
              BrowserOpaqueString.equals(ack.filename, "browser_pages.jsonl"),
              BrowserOpaqueString.equals(ack.requestedDay, period.requestedDay),
              BrowserOpaqueString.equals(ack.requestedSegment, period.requestedSegment),
              ack.size == UInt64(period.committedLength),
              BrowserOpaqueString.equals(ack.sha256, period.fileSha256),
              BrowserOpaqueString.equals(ack.canonicalKey, period.canonicalKey),
              ack.metadata == nil,
              (ack.physicalSegment == nil) == (ack.physicalStream == nil),
              ack.physicalSegment.map({ !$0.isEmpty }) ?? true,
              ack.physicalStream.map({ !$0.isEmpty }) ?? true else { return nil }
        let candidates = listing.items.filter { item in
            let hasSegment = item.segment != nil
            let hasStream = item.stream != nil
            guard hasSegment == hasStream else { return false }

            if let segment = item.segment, let stream = item.stream {
                guard BrowserOpaqueString.equals(segment, ack.requestedSegment) else { return false }
                if let expectedSegment = ack.physicalSegment,
                   let expectedStream = ack.physicalStream {
                    guard BrowserOpaqueString.equals(segment, expectedSegment),
                          BrowserOpaqueString.equals(stream, expectedStream) else { return false }
                }
            } else {
                // Coordinate-free entries are valid only for an ordinary key,
                // never for an opaque collision alias or an original-key alias.
                guard ack.status != .collision,
                      item.originalKey == nil,
                      let canonicalKey = ack.canonicalKey,
                      BrowserOpaqueString.equals(item.key, canonicalKey) else { return false }
            }
            if let original = item.originalKey,
               !BrowserOpaqueString.equals(original, ack.requestedSegment) { return false }
            guard hasUniqueLocalCandidate(period: period, ack: ack) else { return false }
            return item.files.contains { file in
                BrowserOpaqueString.equals(file.effectiveName, ack.filename)
                    && file.size == ack.size
                    && BrowserOpaqueString.equals(file.sha256, ack.sha256)
                    && file.status.provesHold
            }
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private func hasUniqueLocalCandidate(period: BrowserStoredPeriod, ack: BrowserIngestAck) -> Bool {
        guard let expectedLength = Int(exactly: ack.size) else { return false }
        let candidates = store.getAllFinalizedPeriods().filter { candidate in
            BrowserOpaqueString.equals(candidate.requestedDay, ack.requestedDay)
                && BrowserOpaqueString.equals(candidate.requestedSegment, ack.requestedSegment)
                && candidate.committedLength == expectedLength
                && BrowserOpaqueString.equals(candidate.fileSha256, ack.sha256)
        }
        return candidates.count == 1 && candidates[0].periodId == period.periodId
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

    private func isCurrent(period: BrowserStoredPeriod, capture: DeliveryCapture, lease: BrowserUploadLease?) -> Bool {
        guard lease?.isValid() ?? true,
              gate.isPermitActive(capture.permit),
              routeState.matches(capture.route) else {
            Logger.upload.warning("Browser operation skipped for replaced route at period \(period.periodId, privacy: .public)")
            return false
        }
        return true
    }

    private func recordDeliveryFailure(_ failure: String?, period: BrowserStoredPeriod, capture: DeliveryCapture, lease: BrowserUploadLease) {
        guard isCurrent(period: period, capture: capture, lease: lease) else { return }
        store.setDeliveryFailure(failure)
    }

    private func failStorage(period: BrowserStoredPeriod, error: Error, capture: DeliveryCapture, lease: BrowserUploadLease? = nil) {
        guard isCurrent(period: period, capture: capture, lease: lease) else { return }
        guard let current = store.getPeriod(periodId: period.periodId),
              current.state != "discarded", !current.cleanupDurable else {
            Logger.storage.error("Browser spool read failure ignored after period \(period.periodId, privacy: .public) was discarded or cleaned up: \(error.localizedDescription, privacy: .public)")
            return
        }
        Logger.storage.error("Browser spool read failed for period \(period.periodId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        store.setStoreFailed(true)
    }
}

#endif
