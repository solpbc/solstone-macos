// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

private let importLog = Logger(subsystem: "app.solstone.observer", category: "import")

/// Sends one save, one start, one inspect, and resumable chunk upload operations.
/// The live transport streams files from disk; tests fake it.
protocol ImportTransport: Sendable {
    func save(_ item: ImportItemDescriptor, serverURL: String) async -> ImportOutcome
    func start(path: String, timestamp: String, serverURL: String) async -> ImportOutcome
    func inspect(importID: String, serverURL: String) async -> ImportInspectOutcome
    func probeResumableCapabilities(serverURL: String) async -> ImportCapabilityProbeOutcome
    func createUpload(_ request: ImportUploadCreateRequest, serverURL: String) async -> ImportUploadCreateOutcome
    func putUploadChunk(uploadID: String, offset: Int64, data: Data, chunkSHA256: String, serverURL: String) async -> ImportUploadChunkOutcome
    func uploadStatus(uploadID: String, serverURL: String) async -> ImportUploadStatusOutcome
    func commitUpload(uploadID: String, sha256: String, serverURL: String) async -> ImportUploadCommitOutcome
    func abortUpload(uploadID: String, serverURL: String) async -> ImportUploadAbortOutcome
}

extension ImportTransport {
    func probeResumableCapabilities(serverURL: String) async -> ImportCapabilityProbeOutcome { .unsupported }
    func createUpload(_ request: ImportUploadCreateRequest, serverURL: String) async -> ImportUploadCreateOutcome { .unsupported }
    func putUploadChunk(uploadID: String, offset: Int64, data: Data, chunkSHA256: String, serverURL: String) async -> ImportUploadChunkOutcome { .retry(cause: "unsupported") }
    func uploadStatus(uploadID: String, serverURL: String) async -> ImportUploadStatusOutcome { .retry(cause: "unsupported") }
    func commitUpload(uploadID: String, sha256: String, serverURL: String) async -> ImportUploadCommitOutcome { .retry(cause: "unsupported") }
    func abortUpload(uploadID: String, serverURL: String) async -> ImportUploadAbortOutcome { .notFound }
}

/// Cached outcome of probing a paired journal's resumable import upload capability.
enum ImportCachedResumableCapability: Equatable, Sendable {
    case supported(ImportResumableCapabilities)
    case unsupported
}

enum ImportReconcileResult: Equatable, Sendable {
    case clean
    /// The journal returned 401/403; the batch halted without deleting local bytes.
    case authStop
    /// Pairing or admission changed mid-batch.
    case pairingLeft
}

enum ImportRunResult: Equatable, Sendable {
    /// Every item it took was delivered, refused or saved.
    case clean
    /// At least one item is to be tried again later.
    case retry
    /// The journal refused this pairing; the run stopped.
    case authStop
    /// The pairing or the gate changed during the run; it stopped sending.
    case pairingLeft
    /// The Mac is going to sleep or delivery was cancelled; waiting items stay pending for wake.
    case pausedForSleep
    /// The journal's version doesn't take imports, or isn't known; nothing was sent.
    case held
}

/// One owner event-log line for an import left to retry. The id is this Mac's own random one.
func importRetryLine(id: String, stage: String, cause: String) -> String {
    "kind=import id=\(id) step=\(stage) outcome=retry cause=\(cause)"
}

private func shouldPauseForSleep(_ isSleeping: @Sendable () async -> Bool) async -> Bool {
    if Task.isCancelled { return true }
    return await isSleeping()
}

/// Delivers held imports to the paired journal, oldest first. Each item's exchange (save or
/// resumable chunked upload, then start) is marked in the store so the owner can't remove it
/// mid-flight, and each answer is recorded and the exchange ended under the store's lock. An
/// answer from the journal a request went to counts even if the owner re-paired meanwhile: that
/// journal has it. A save or commit answer that arrives after a re-pair sends no start. A retry
/// moves on to the next item.
func deliverImports(
    transport: any ImportTransport,
    store: ImportCustodyStore,
    serverURL: String,
    resolveServerURL: (@Sendable () async -> String?)? = nil,
    instance: String,
    journalVersion: String,
    gate: ImportVersionGate,
    stillCurrent: @Sendable () async -> Bool,
    isSleeping: @Sendable () async -> Bool = { false },
    isCancelledForItem: @Sendable (String) async -> Bool = { _ in false },
    cachedCapabilities: @Sendable () async -> ImportCachedResumableCapability? = { nil },
    storeCapabilities: @Sendable (ImportCachedResumableCapability) async -> Void = { _ in },
    onProgress: @Sendable () -> Void = {},
    chunkJitterUnit: @Sendable () -> Double = { Double.random(in: 0...1) },
    now: @Sendable () -> Date,
    log: @Sendable (String) -> Void = { importLog.notice("\($0, privacy: .public)") }
) async -> ImportRunResult {
    guard gate == .supported else { return .held }
    let activeServerURL: @Sendable () async -> String = {
        if let resolved = await resolveServerURL?(), !resolved.isEmpty {
            return resolved
        }
        return serverURL
    }
    var anyRetry = false
    var result = ImportRunResult.clean
    defer { store.finish() }
    for candidate in store.eligible(instance: instance, journalVersion: journalVersion, now: now()) {
        if await isCancelledForItem(candidate.id) {
            break
        }
        if await shouldPauseForSleep(isSleeping) {
            result = .pausedForSleep
            break
        }
        guard await stillCurrent() else {
            result = .pairingLeft
            break
        }
        guard store.beginExchange(candidate.id, instance: instance, journalVersion: journalVersion) == .done else { continue }
        let step = await deliverOne(
            transport: transport,
            store: store,
            id: candidate.id,
            saved: candidate.progress,
            resolveServerURL: activeServerURL,
            instance: instance,
            journalVersion: journalVersion,
            stillCurrent: stillCurrent,
            isSleeping: isSleeping,
            isCancelledForItem: isCancelledForItem,
            cachedCapabilities: cachedCapabilities,
            storeCapabilities: storeCapabilities,
            onProgress: onProgress,
            now: now
        )
        store.endExchange(candidate.id)
        switch step {
        case .done:
            onProgress()
        case .cancelled:
            onProgress()
            return result
        case .retry(let stage, let cause):
            log(importRetryLine(id: candidate.id, stage: stage, cause: cause))
            store.markRetry(candidate.id, instance: instance, now: now())
            anyRetry = true
        case .resumableRetry(let stage, let cause):
            log(importRetryLine(id: candidate.id, stage: stage, cause: cause))
            store.markUploadPaused(
                candidate.id,
                instance: instance,
                now: now(),
                applyBackoff: true,
                jitterUnit: chunkJitterUnit()
            )
            onProgress()
            anyRetry = true
        case .authStop:
            result = .authStop
        case .pairingLeft:
            result = .pairingLeft
        case .pausedForSleep:
            onProgress()
            result = .pausedForSleep
        }
        if result != .clean { break }
    }
    if result == .clean && anyRetry { result = .retry }
    return result
}

private enum ImportItemStep {
    case done
    case cancelled
    case retry(stage: String, cause: String)
    case resumableRetry(stage: String, cause: String)
    case authStop
    case pairingLeft
    case pausedForSleep
}

private func resolveCapabilitiesForItem(
    transport: any ImportTransport,
    serverURL: String,
    cachedCapabilities: @Sendable () async -> ImportCachedResumableCapability?,
    storeCapabilities: @Sendable (ImportCachedResumableCapability) async -> Void
) async -> ImportCapabilityProbeOutcome {
    if let cached = await cachedCapabilities() {
        switch cached {
        case .supported(let caps): return .supported(caps)
        case .unsupported: return .unsupported
        }
    }
    let probed = await transport.probeResumableCapabilities(serverURL: serverURL)
    switch probed {
    case .supported(let caps):
        await storeCapabilities(.supported(caps))
    case .unsupported:
        await storeCapabilities(.unsupported)
    case .authStop, .retry:
        break
    }
    return probed
}

private func deliverOne(
    transport: any ImportTransport,
    store: ImportCustodyStore,
    id: String,
    saved: (path: String, timestamp: String)?,
    resolveServerURL: @Sendable () async -> String,
    instance: String,
    journalVersion: String,
    stillCurrent: @Sendable () async -> Bool,
    isSleeping: @Sendable () async -> Bool,
    isCancelledForItem: @Sendable (String) async -> Bool,
    cachedCapabilities: @Sendable () async -> ImportCachedResumableCapability?,
    storeCapabilities: @Sendable (ImportCachedResumableCapability) async -> Void,
    onProgress: @Sendable () -> Void,
    now: @Sendable () -> Date
) async -> ImportItemStep {
    var progress = saved
    if progress == nil {
        guard let descriptor = store.item(id) else { return .done }
        let url = await resolveServerURL()
        let capability = await resolveCapabilitiesForItem(
            transport: transport,
            serverURL: url,
            cachedCapabilities: cachedCapabilities,
            storeCapabilities: storeCapabilities
        )
        switch capability {
        case .supported(let caps) where descriptor.size >= caps.thresholdBytes:
            let resumableResult = await deliverResumable(
                transport: transport,
                store: store,
                initialDescriptor: descriptor,
                capabilities: caps,
                resolveServerURL: resolveServerURL,
                instance: instance,
                journalVersion: journalVersion,
                stillCurrent: stillCurrent,
                isSleeping: isSleeping,
                isCancelledForItem: isCancelledForItem,
                storeCapabilities: storeCapabilities,
                onProgress: onProgress,
                now: now
            )
            switch resumableResult {
            case .staged(let path, let timestamp):
                progress = (path, timestamp)
            case .fallbackToSave:
                break
            case .finished(let step):
                return step
            }
        case .supported, .unsupported:
            break
        case .authStop:
            return .authStop
        case .retry(let cause):
            if await isCancelledForItem(id) { return .cancelled }
            let hasSession = descriptor.uploadID != nil && descriptor.uploadInstanceID == instance
            if await shouldPauseForSleep(isSleeping) {
                if hasSession {
                    store.markUploadPaused(id, instance: instance, now: now(), applyBackoff: false)
                }
                return .pausedForSleep
            }
            if hasSession {
                return .resumableRetry(stage: "probe", cause: cause)
            }
            return .retry(stage: "probe", cause: cause)
        }
    }
    if progress == nil {
        guard let descriptor = store.item(id) else { return .done }
        let url = await resolveServerURL()
        let outcome = await transport.save(descriptor, serverURL: url)
        if case .saved(let path, let timestamp) = outcome {
            guard await stillCurrent() else { return .pairingLeft }
            if store.recordSaved(id, path: path, timestamp: timestamp, instance: instance) == .gone { return .done }
            progress = (path, timestamp)
            if await isCancelledForItem(id) { return .cancelled }
            if await shouldPauseForSleep(isSleeping) { return .pausedForSleep }
        } else {
            if await isCancelledForItem(id) { return .cancelled }
            if case .retry = outcome, await shouldPauseForSleep(isSleeping) {
                return .pausedForSleep
            }
            return settle(store: store, id: id, outcome: outcome, stage: "save", instance: instance, journalVersion: journalVersion)
        }
    }
    guard let progress else { return .done }
    if await isCancelledForItem(id) { return .cancelled }
    if await shouldPauseForSleep(isSleeping) { return .pausedForSleep }
    guard await stillCurrent() else { return .pairingLeft }
    let startURL = await resolveServerURL()
    let outcome = await transport.start(path: progress.path, timestamp: progress.timestamp, serverURL: startURL)
    if await isCancelledForItem(id) { return .cancelled }
    if case .retry = outcome, await shouldPauseForSleep(isSleeping) {
        return .pausedForSleep
    }
    return settle(
        store: store, id: id, outcome: outcome, stage: "start",
        savedTimestamp: progress.timestamp, instance: instance, journalVersion: journalVersion
    )
}

private enum ResumableTransferResult {
    case staged(path: String, timestamp: String)
    case fallbackToSave
    case finished(ImportItemStep)
}

private func readExactChunk(from handle: FileHandle, offset: Int64, length: Int) -> Data? {
    guard offset >= 0, length > 0 else { return nil }
    do {
        try handle.seek(toOffset: UInt64(offset))
        var buffer = Data()
        buffer.reserveCapacity(length)
        while buffer.count < length {
            guard let part = try handle.read(upToCount: length - buffer.count), !part.isEmpty else {
                return nil
            }
            buffer.append(part)
        }
        return buffer
    } catch {
        return nil
    }
}

private func deliverResumable(
    transport: any ImportTransport,
    store: ImportCustodyStore,
    initialDescriptor: ImportItemDescriptor,
    capabilities: ImportResumableCapabilities,
    resolveServerURL: @Sendable () async -> String,
    instance: String,
    journalVersion: String,
    stillCurrent: @Sendable () async -> Bool,
    isSleeping: @Sendable () async -> Bool,
    isCancelledForItem: @Sendable (String) async -> Bool,
    storeCapabilities: @Sendable (ImportCachedResumableCapability) async -> Void,
    onProgress: @Sendable () -> Void,
    now: @Sendable () -> Date
) async -> ResumableTransferResult {
    let id = initialDescriptor.id
    var descriptor = initialDescriptor

    // Belt-and-suspenders pairing-switch guard: never reuse an upload session from another journal.
    if let boundInstance = descriptor.uploadInstanceID, boundInstance != instance {
        _ = store.clearUploadSession(id, clearSHA256: false)
        guard let refreshed = store.item(id) else { return .finished(.done) }
        descriptor = refreshed
    }

    let hadExistingSession = descriptor.uploadID != nil && descriptor.uploadInstanceID == instance
    let wasResuming = hadExistingSession && (descriptor.uploadPaused || (descriptor.uploadOffset ?? 0) > 0)
    store.setLiveUploadPhase(id, phase: .sending, resuming: wasResuming)
    onProgress()

    // Step 1: stream-hash whole file once from local custody copy (O(1) memory).
    let fileSHA256: String
    if let cachedHash = descriptor.sha256, cachedHash.count == 64 {
        fileSHA256 = cachedHash
    } else {
        let hashResult = importFileSHA256(at: descriptor.payloadURL, expectedSize: descriptor.size)
        switch hashResult {
        case .hashed(let hex):
            fileSHA256 = hex
            _ = store.recordSHA256(id, sha256: hex)
        case .unreadable:
            _ = store.recordMissingCopy(id)
            return .finished(.done)
        case .cancelled:
            if await isCancelledForItem(id) { return .finished(.cancelled) }
            if await shouldPauseForSleep(isSleeping) { return .finished(.pausedForSleep) }
            return .finished(.resumableRetry(stage: "hash", cause: "io-cancelled"))
        }
    }

    let createRequest = ImportUploadCreateRequest(
        clientItemID: id,
        filename: descriptor.displayName,
        mimeType: descriptor.mime,
        totalBytes: descriptor.size,
        sha256: fileSHA256,
        importedVia: ImportLiveTransport.importedVia,
        deviceNoun: ImportLiveTransport.deviceNoun,
        handoff: descriptor.handoff
    )

    func pauseForSleepIfNeeded(hasSession: Bool) -> ResumableTransferResult {
        if hasSession {
            store.markUploadPaused(id, instance: instance, now: now(), applyBackoff: false)
        }
        return .finished(.pausedForSleep)
    }

    func surfaceUploadNotFound() -> ResumableTransferResult {
        _ = store.recordAttention(
            id,
            error: importGenericRefusal,
            reasonCode: "upload_not_found",
            kind: nil,
            instance: instance,
            journalVersion: journalVersion,
            preserveUploadSession: false
        )
        return .finished(.done)
    }

    // Checks once via idempotent POST /uploads whether a lost commit already staged/imported the file.
    func probeLostCommitAfterNotFound() async -> ResumableTransferResult {
        let probeURL = await resolveServerURL()
        let probe = await transport.createUpload(createRequest, serverURL: probeURL)
        switch probe {
        case .alreadyStaged(let path, let timestamp):
            guard await stillCurrent() else { return .finished(.pairingLeft) }
            if store.recordSaved(id, path: path, timestamp: timestamp, instance: instance) == .gone {
                return .finished(.done)
            }
            return .staged(path: path, timestamp: timestamp)
        case .alreadyImported(let importID):
            _ = store.recordDelivered(id, instance: instance, importID: importID)
            return .finished(.done)
        case .open(let freshID, _, _, _, _):
            // Not staged — previous upload truly expired or was aborted before commit.
            // Clean up the probe session right away and surface the real fault to the owner.
            _ = await transport.abortUpload(uploadID: freshID, serverURL: probeURL)
            return surfaceUploadNotFound()
        case .unsupported:
            await storeCapabilities(.unsupported)
            _ = store.clearUploadSession(id, clearSHA256: false)
            return .fallbackToSave
        case .insufficientSpace(let error, _, _):
            _ = store.recordAttention(
                id, error: error, reasonCode: "insufficient_journal_space", kind: nil,
                instance: instance, journalVersion: journalVersion, preserveUploadSession: false
            )
            return .finished(.done)
        case .authStop:
            return .finished(.authStop)
        case .retry(let cause):
            if await isCancelledForItem(id) { return .finished(.cancelled) }
            if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: true) }
            return .finished(.resumableRetry(stage: "upload-commit-check", cause: cause))
        case .needsAttention(let error, let reasonCode, let kind):
            _ = store.recordAttention(
                id, error: error, reasonCode: reasonCode ?? "", kind: kind,
                instance: instance, journalVersion: journalVersion, preserveUploadSession: false
            )
            return .finished(.done)
        }
    }

    // Step 2: Open new upload session or resync existing open session via GET /uploads/{id}.
    var uploadID: String
    var offset: Int64
    var chunkBytes: Int64 = capabilities.chunkBytes

    if let existingID = descriptor.uploadID, !existingID.isEmpty, descriptor.uploadInstanceID == instance {
        if await isCancelledForItem(id) { return .finished(.cancelled) }
        if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: true) }
        guard await stillCurrent() else {
            store.markUploadPaused(id, instance: instance, now: now(), applyBackoff: false)
            return .finished(.pairingLeft)
        }
        let statusURL = await resolveServerURL()
        let statusOutcome = await transport.uploadStatus(uploadID: existingID, serverURL: statusURL)
        switch statusOutcome {
        case .open(let syncedID, let nextOffset, let totalBytes, let syncedChunkBytes, _, _):
            guard totalBytes == descriptor.size, nextOffset >= 0, nextOffset <= descriptor.size else {
                return surfaceUploadNotFound()
            }
            guard await stillCurrent() else {
                store.markUploadPaused(id, instance: instance, now: now(), applyBackoff: false)
                return .finished(.pairingLeft)
            }
            if store.recordUploadOpen(id, uploadID: syncedID, nextOffset: nextOffset, chunkBytes: syncedChunkBytes, instance: instance) == .gone {
                return .finished(.done)
            }
            uploadID = syncedID
            offset = nextOffset
            chunkBytes = syncedChunkBytes
            onProgress()
        case .uploadNotFound:
            if (descriptor.uploadOffset ?? 0) >= descriptor.size {
                return await probeLostCommitAfterNotFound()
            }
            return surfaceUploadNotFound()
        case .authStop:
            return .finished(.authStop)
        case .retry(let cause):
            if await isCancelledForItem(id) { return .finished(.cancelled) }
            if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: true) }
            return .finished(.resumableRetry(stage: "upload-status", cause: cause))
        }
    } else {
        if await isCancelledForItem(id) { return .finished(.cancelled) }
        if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: false) }
        guard await stillCurrent() else { return .finished(.pairingLeft) }
        let createURL = await resolveServerURL()
        let createOutcome = await transport.createUpload(createRequest, serverURL: createURL)
        switch createOutcome {
        case .open(let createdID, let nextOffset, let totalBytes, let createdChunkBytes, _):
            guard totalBytes == descriptor.size, nextOffset >= 0, nextOffset <= descriptor.size else {
                return .finished(.resumableRetry(stage: "upload-create", cause: "answer-size-mismatch"))
            }
            guard await stillCurrent() else { return .finished(.pairingLeft) }
            if store.recordUploadOpen(id, uploadID: createdID, nextOffset: nextOffset, chunkBytes: createdChunkBytes, instance: instance) == .gone {
                return .finished(.done)
            }
            uploadID = createdID
            offset = nextOffset
            chunkBytes = createdChunkBytes
            onProgress()
        case .alreadyStaged(let path, let timestamp):
            guard await stillCurrent() else { return .finished(.pairingLeft) }
            if store.recordSaved(id, path: path, timestamp: timestamp, instance: instance) == .gone {
                return .finished(.done)
            }
            return .staged(path: path, timestamp: timestamp)
        case .alreadyImported(let importID):
            _ = store.recordDelivered(id, instance: instance, importID: importID)
            return .finished(.done)
        case .unsupported:
            await storeCapabilities(.unsupported)
            return .fallbackToSave
        case .insufficientSpace(let error, _, _):
            _ = store.recordAttention(
                id, error: error, reasonCode: "insufficient_journal_space", kind: nil,
                instance: instance, journalVersion: journalVersion, preserveUploadSession: false
            )
            return .finished(.done)
        case .authStop:
            return .finished(.authStop)
        case .retry(let cause):
            if await isCancelledForItem(id) { return .finished(.cancelled) }
            if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: false) }
            return .finished(.resumableRetry(stage: "upload-create", cause: cause))
        case .needsAttention(let error, let reasonCode, let kind):
            _ = store.recordAttention(
                id, error: error, reasonCode: reasonCode ?? "", kind: kind,
                instance: instance, journalVersion: journalVersion, preserveUploadSession: false
            )
            return .finished(.done)
        }
    }

    // Step 3 + 4: Stream chunks from disk until offset == totalBytes, then commit.
    // Bounded outer loop allows cleanly re-sending missing tail bytes if commit returns 409 incomplete_upload.
    var commitCycles = 0
    while commitCycles < 3 {
        commitCycles += 1

        if offset < descriptor.size {
            guard let handle = try? FileHandle(forReadingFrom: descriptor.payloadURL) else {
                _ = store.recordMissingCopy(id)
                return .finished(.done)
            }
            defer { try? handle.close() }

            var checksumRetriesAtOffset = 0
            var staleOffsetRetries = 0

            while offset < descriptor.size {
                if await isCancelledForItem(id) { return .finished(.cancelled) }
                if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: true) }
                guard await stillCurrent() else {
                    store.markUploadPaused(id, instance: instance, now: now(), applyBackoff: false)
                    return .finished(.pairingLeft)
                }

                let want = Int(min(chunkBytes, descriptor.size - offset))
                let prepared: (data: Data, sha256: String)? = autoreleasepool {
                    guard let chunk = readExactChunk(from: handle, offset: offset, length: want) else {
                        return nil
                    }
                    return (chunk, importDataSHA256(chunk))
                }
                guard let prepared else {
                    _ = store.recordMissingCopy(id)
                    return .finished(.done)
                }

                let chunkURL = await resolveServerURL()
                let chunkOutcome = await transport.putUploadChunk(
                    uploadID: uploadID,
                    offset: offset,
                    data: prepared.data,
                    chunkSHA256: prepared.sha256,
                    serverURL: chunkURL
                )
                switch chunkOutcome {
                case .accepted(let nextOffset, _, _, _):
                    let clamped = min(descriptor.size, max(offset, nextOffset))
                    if clamped == offset && offset < descriptor.size {
                        staleOffsetRetries += 1
                        if staleOffsetRetries >= 3 {
                            return .finished(.resumableRetry(stage: "upload-chunk", cause: "no-offset-progress"))
                        }
                    } else {
                        staleOffsetRetries = 0
                    }
                    checksumRetriesAtOffset = 0
                    offset = clamped
                    if store.recordUploadProgress(id, nextOffset: offset, instance: instance) == .gone {
                        return .finished(.done)
                    }
                    onProgress()
                case .offsetMismatch(let serverOffset):
                    if let serverOffset, serverOffset >= 0, serverOffset <= descriptor.size {
                        if serverOffset != offset {
                            offset = serverOffset
                            checksumRetriesAtOffset = 0
                            staleOffsetRetries = 0
                            if store.recordUploadProgress(id, nextOffset: offset, instance: instance) == .gone {
                                return .finished(.done)
                            }
                            onProgress()
                        } else {
                            staleOffsetRetries += 1
                            if staleOffsetRetries >= 3 {
                                return .finished(.resumableRetry(stage: "upload-chunk", cause: "offset-mismatch-loop"))
                            }
                        }
                    } else {
                        // Bodyless 409 from an intermediate proxy: resync offset via GET /uploads/{id}.
                        let syncURL = await resolveServerURL()
                        switch await transport.uploadStatus(uploadID: uploadID, serverURL: syncURL) {
                        case .open(_, let syncedOffset, let totalBytes, let syncedChunkBytes, _, _):
                            guard totalBytes == descriptor.size, syncedOffset >= 0, syncedOffset <= descriptor.size else {
                                return surfaceUploadNotFound()
                            }
                            if syncedOffset == offset {
                                staleOffsetRetries += 1
                                if staleOffsetRetries >= 3 {
                                    return .finished(.resumableRetry(stage: "upload-chunk", cause: "offset-mismatch-loop"))
                                }
                            } else {
                                staleOffsetRetries = 0
                            }
                            offset = syncedOffset
                            chunkBytes = syncedChunkBytes
                            checksumRetriesAtOffset = 0
                            if store.recordUploadProgress(id, nextOffset: offset, instance: instance) == .gone {
                                return .finished(.done)
                            }
                            onProgress()
                        case .uploadNotFound:
                            return surfaceUploadNotFound()
                        case .authStop:
                            return .finished(.authStop)
                        case .retry(let cause):
                            if await isCancelledForItem(id) { return .finished(.cancelled) }
                            if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: true) }
                            return .finished(.resumableRetry(stage: "upload-status", cause: cause))
                        }
                    }
                case .chunkChecksumMismatch(let serverOffset):
                    if let serverOffset, serverOffset >= 0, serverOffset <= descriptor.size, serverOffset != offset {
                        offset = serverOffset
                        checksumRetriesAtOffset = 0
                        if store.recordUploadProgress(id, nextOffset: offset, instance: instance) == .gone {
                            return .finished(.done)
                        }
                        onProgress()
                    } else {
                        checksumRetriesAtOffset += 1
                        if checksumRetriesAtOffset > 3 {
                            return .finished(.resumableRetry(stage: "upload-chunk", cause: "chunk-checksum-mismatch"))
                        }
                    }
                case .uploadNotFound:
                    return surfaceUploadNotFound()
                case .insufficientSpace(let error):
                    _ = store.recordAttention(
                        id,
                        error: error,
                        reasonCode: "insufficient_journal_space",
                        kind: nil,
                        instance: instance,
                        journalVersion: journalVersion,
                        preserveUploadSession: true
                    )
                    return .finished(.done)
                case .authStop:
                    return .finished(.authStop)
                case .retry(let cause):
                    if await isCancelledForItem(id) { return .finished(.cancelled) }
                    if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: true) }
                    return .finished(.resumableRetry(stage: "upload-chunk", cause: cause))
                case .needsAttention(let error, let reasonCode, let kind):
                    _ = store.recordAttention(
                        id, error: error, reasonCode: reasonCode ?? "", kind: kind,
                        instance: instance, journalVersion: journalVersion, preserveUploadSession: false
                    )
                    return .finished(.done)
                }
            }
        }

        // Step 4: Commit the complete upload and verify whole-file SHA-256 on the journal.
        if await isCancelledForItem(id) { return .finished(.cancelled) }
        if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: true) }
        guard await stillCurrent() else {
            store.markUploadPaused(id, instance: instance, now: now(), applyBackoff: false)
            return .finished(.pairingLeft)
        }

        store.setLiveUploadPhase(id, phase: .checking, resuming: false)
        onProgress()

        let commitURL = await resolveServerURL()
        let commitOutcome = await transport.commitUpload(uploadID: uploadID, sha256: fileSHA256, serverURL: commitURL)
        switch commitOutcome {
        case .staged(let path, let timestamp):
            guard await stillCurrent() else { return .finished(.pairingLeft) }
            if store.recordSaved(id, path: path, timestamp: timestamp, instance: instance) == .gone {
                return .finished(.done)
            }
            return .staged(path: path, timestamp: timestamp)
        case .wholeFileChecksumMismatch(let error):
            _ = store.recordAttention(
                id,
                error: error,
                reasonCode: "whole_file_checksum_mismatch",
                kind: nil,
                instance: instance,
                journalVersion: journalVersion,
                preserveUploadSession: false,
                clearSHA256: true
            )
            return .finished(.done)
        case .incompleteUpload(let serverOffset):
            if let serverOffset, serverOffset >= 0, serverOffset < descriptor.size {
                offset = serverOffset
                if store.recordUploadProgress(id, nextOffset: offset, instance: instance) == .gone {
                    return .finished(.done)
                }
                onProgress()
                continue
            }
            // Bodyless 409 on commit: resync offset via GET.
            let syncURL = await resolveServerURL()
            switch await transport.uploadStatus(uploadID: uploadID, serverURL: syncURL) {
            case .open(_, let syncedOffset, let totalBytes, let syncedChunkBytes, _, _):
                guard totalBytes == descriptor.size, syncedOffset >= 0, syncedOffset <= descriptor.size else {
                    return surfaceUploadNotFound()
                }
                offset = syncedOffset
                chunkBytes = syncedChunkBytes
                if store.recordUploadProgress(id, nextOffset: offset, instance: instance) == .gone {
                    return .finished(.done)
                }
                onProgress()
                continue
            case .uploadNotFound:
                return await probeLostCommitAfterNotFound()
            case .authStop:
                return .finished(.authStop)
            case .retry(let cause):
                if await isCancelledForItem(id) { return .finished(.cancelled) }
                if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: true) }
                return .finished(.resumableRetry(stage: "upload-status", cause: cause))
            }
        case .uploadNotFound:
            return await probeLostCommitAfterNotFound()
        case .authStop:
            return .finished(.authStop)
        case .retry(let cause):
            if await isCancelledForItem(id) { return .finished(.cancelled) }
            if await shouldPauseForSleep(isSleeping) { return pauseForSleepIfNeeded(hasSession: true) }
            return .finished(.resumableRetry(stage: "upload-commit", cause: cause))
        case .needsAttention(let error, let reasonCode, let kind):
            _ = store.recordAttention(
                id, error: error, reasonCode: reasonCode ?? "", kind: kind,
                instance: instance, journalVersion: journalVersion, preserveUploadSession: false
            )
            return .finished(.done)
        }
    }

    return .finished(.resumableRetry(stage: "upload-commit", cause: "incomplete-upload-loop"))
}

private func settle(
    store: ImportCustodyStore,
    id: String,
    outcome: ImportOutcome,
    stage: String,
    savedTimestamp: String? = nil,
    instance: String,
    journalVersion: String
) -> ImportItemStep {
    switch outcome {
    case .delivered(let importID):
        _ = store.recordDelivered(id, instance: instance, importID: importID)
        return .done
    case .readyToReview(let responseImportID, let error, let reasonCode, let kind):
        if let importID = validImportID(responseImportID) ?? validImportID(savedTimestamp) {
            _ = store.recordReadyToReview(
                id, importID: importID, error: error, reasonCode: reasonCode, kind: kind, instance: instance
            )
        } else {
            _ = store.recordAttention(
                id,
                error: error.isEmpty ? importGenericRefusal : error,
                reasonCode: reasonCode,
                kind: kind,
                instance: instance,
                journalVersion: journalVersion
            )
        }
        return .done
    case .needsAttention(let error, let reasonCode, let kind):
        _ = store.recordAttention(id, error: error, reasonCode: reasonCode ?? "", kind: kind, instance: instance, journalVersion: journalVersion)
        return .done
    case .authStop:
        return .authStop
    case .retry(let cause):
        return .retry(stage: stage, cause: cause)
    case .saved:
        // At start this means the journal answered something else: try again later.
        return .retry(stage: stage, cause: "answer-saved")
    }
}

/// Safely reconciles `ready to review` items against `GET /app/import/api/<id>`.
/// Re-verifies `(id, saved_import_id, saved_instance_id)` under the store lock before mutating,
/// persists any 24h recent receipt durably before deleting local bytes, preserves bytes on
/// `pending + eligible/unknown/absent`, marks `404` as `reviewExpired` keeping local bytes,
/// halts immediately on `401`/`403`, and ignores transient/malformed errors per item.
func reconcileReviewImports(
    transport: any ImportTransport,
    store: ImportCustodyStore,
    serverURL: String,
    instance: String,
    stillCurrent: @Sendable () async -> Bool
) async -> ImportReconcileResult {
    defer { store.finish() }
    for candidate in store.reviewCandidates(instance: instance) {
        guard await stillCurrent() else { return .pairingLeft }
        let outcome = await transport.inspect(importID: candidate.importID, serverURL: serverURL)
        switch outcome {
        case .confirmed:
            _ = store.reconcileConfirmed(
                candidate.id,
                expectedImportID: candidate.importID,
                expectedInstanceID: candidate.instanceID
            )
        case .expired:
            _ = store.reconcileExpired(
                candidate.id,
                expectedImportID: candidate.importID,
                expectedInstanceID: candidate.instanceID
            )
        case .stillPending, .unchanged:
            break
        case .authStop:
            return .authStop
        }
    }
    return .clean
}

// MARK: - the live transport

/// Streams a save's multipart body from the copy on disk, never holding the file in memory, over
/// the paired connection, and sends resumable chunked uploads and control calls over a cache-free
/// pooled session. Redirects are never followed.
struct ImportLiveTransport: ImportTransport {
    static let savePath = "/app/import/api/save"
    static let startPath = "/app/import/api/start"
    static let inspectPrefix = "/app/import/api/"
    static let systemStatusPath = "/api/system/status"
    static let sourcesPath = "/app/import/api/sources"
    static let uploadsPath = "/app/import/api/uploads"
    /// The journal labels the import's origin from this; older journals show no label for it.
    static let importedVia = "macos"
    /// Allowlisted `device_noun` in the journal client contract (`mac`).
    static let deviceNoun = "mac"
    static let chunkSize = 64 * 1024

    private let httpSession: ImportHTTPSession

    static func defaultChunkSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120
        config.httpMaximumConnectionsPerHost = BoundedLoopbackClient.uploadConnectionsPerHost
        return config
    }

    init(sessionConfiguration: URLSessionConfiguration? = nil) {
        self.httpSession = ImportHTTPSession(configuration: sessionConfiguration ?? Self.defaultChunkSessionConfiguration())
    }

    private static func isSafeUploadID(_ uploadID: String) -> Bool {
        !uploadID.isEmpty
            && uploadID.count <= 128
            && uploadID.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
            }
    }

    func save(_ item: ImportItemDescriptor, serverURL: String) async -> ImportOutcome {
        guard let url = URL(string: serverURL + Self.savePath) else { return .retry(cause: "io-address") }
        let boundary = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let body = ImportMultipartBody(boundary: boundary, item: item)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(body.contentLength), forHTTPHeaderField: "Content-Length")
        request.attachLoopbackCapability()
        let answer = await ImportStreamedRequest.send(request, body: body)
        return Self.classify(.save, answer)
    }

    func start(path: String, timestamp: String, serverURL: String) async -> ImportOutcome {
        guard let url = URL(string: serverURL + Self.startPath),
              let json = try? JSONSerialization.data(withJSONObject: ["path": path, "timestamp": timestamp], options: [.sortedKeys]) else {
            return .retry(cause: "io-address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = json
        request.attachLoopbackCapability()
        let answer = await httpSession.send(request)
        return Self.classify(.start, answer)
    }

    func inspect(importID: String, serverURL: String) async -> ImportInspectOutcome {
        guard isValidImportID(importID),
              let url = URL(string: serverURL + Self.inspectPrefix + importID) else {
            return .unchanged
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.attachLoopbackCapability()
        let answer = await httpSession.send(request)
        switch answer {
        case .failed:
            return .unchanged
        case .answered(let status, let loopbackRefused, let data):
            return classifyImportInspectResponse(status: status, body: data, loopbackRefused: status == 403 && loopbackRefused)
        }
    }

    func probeResumableCapabilities(serverURL: String) async -> ImportCapabilityProbeOutcome {
        guard let statusURL = URL(string: serverURL + Self.systemStatusPath) else {
            return .retry(cause: "io-address")
        }
        var statusReq = URLRequest(url: statusURL)
        statusReq.httpMethod = "GET"
        statusReq.setValue("application/json", forHTTPHeaderField: "Accept")
        statusReq.attachLoopbackCapability()
        switch await httpSession.send(statusReq) {
        case .failed(let cause):
            return .retry(cause: cause)
        case .answered(let status, let loopbackRefused, let data):
            if status == 403 && loopbackRefused { return .retry(cause: "loopback-refused") }
            if status == 401 || status == 403 { return .authStop }
            if status == 404 || status == 405 { return .unsupported }
            if status == 408 || (500...599).contains(status) { return .retry(cause: "http-\(status)") }
            guard status == 200 else { return .unsupported }
            guard let advertised = parseSystemStatusResumableCapability(data) else {
                return .retry(cause: "unreadable-answer")
            }
            guard advertised else { return .unsupported }
        }

        guard let sourcesURL = URL(string: serverURL + Self.sourcesPath) else {
            return .retry(cause: "io-address")
        }
        var sourcesReq = URLRequest(url: sourcesURL)
        sourcesReq.httpMethod = "GET"
        sourcesReq.setValue("application/json", forHTTPHeaderField: "Accept")
        sourcesReq.attachLoopbackCapability()
        switch await httpSession.send(sourcesReq) {
        case .failed(let cause):
            return .retry(cause: cause)
        case .answered(let status, let loopbackRefused, let data):
            if status == 403 && loopbackRefused { return .retry(cause: "loopback-refused") }
            if status == 401 || status == 403 { return .authStop }
            if status == 404 || status == 405 { return .unsupported }
            if status == 408 || (500...599).contains(status) { return .retry(cause: "http-\(status)") }
            guard status == 200 else { return .unsupported }
            if let caps = parseSourcesResumableCapabilities(data) {
                return .supported(caps)
            }
            return .unsupported
        }
    }

    func createUpload(_ body: ImportUploadCreateRequest, serverURL: String) async -> ImportUploadCreateOutcome {
        guard let url = URL(string: serverURL + Self.uploadsPath),
              let json = body.encodedJSON() else {
            return .retry(cause: "io-address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(json.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = json
        request.attachLoopbackCapability()
        switch await httpSession.send(request) {
        case .failed(let cause):
            return .retry(cause: cause)
        case .answered(let status, let loopbackRefused, let data):
            return classifyUploadCreateResponse(status: status, body: data, loopbackRefused: status == 403 && loopbackRefused)
        }
    }

    func putUploadChunk(
        uploadID: String,
        offset: Int64,
        data: Data,
        chunkSHA256: String,
        serverURL: String
    ) async -> ImportUploadChunkOutcome {
        guard Self.isSafeUploadID(uploadID),
              offset >= 0,
              !data.isEmpty,
              let url = URL(string: "\(serverURL)\(Self.uploadsPath)/\(uploadID)?offset=\(offset)") else {
            return .retry(cause: "io-address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue(chunkSHA256, forHTTPHeaderField: "X-Chunk-Sha256")
        request.httpBody = nil
        request.attachLoopbackCapability()
        switch await httpSession.send(request, uploadBody: data) {
        case .failed(let cause):
            return .retry(cause: cause)
        case .answered(let status, let loopbackRefused, let responseData):
            return classifyUploadChunkResponse(status: status, body: responseData, loopbackRefused: status == 403 && loopbackRefused)
        }
    }

    func uploadStatus(uploadID: String, serverURL: String) async -> ImportUploadStatusOutcome {
        guard Self.isSafeUploadID(uploadID),
              let url = URL(string: "\(serverURL)\(Self.uploadsPath)/\(uploadID)") else {
            return .retry(cause: "io-address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.attachLoopbackCapability()
        switch await httpSession.send(request) {
        case .failed(let cause):
            return .retry(cause: cause)
        case .answered(let status, let loopbackRefused, let data):
            return classifyUploadStatusResponse(status: status, body: data, loopbackRefused: status == 403 && loopbackRefused)
        }
    }

    func commitUpload(uploadID: String, sha256: String, serverURL: String) async -> ImportUploadCommitOutcome {
        guard Self.isSafeUploadID(uploadID),
              let url = URL(string: "\(serverURL)\(Self.uploadsPath)/\(uploadID)/commit"),
              let json = try? JSONSerialization.data(withJSONObject: ["sha256": sha256], options: [.sortedKeys]) else {
            return .retry(cause: "io-address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(json.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = json
        request.attachLoopbackCapability()
        switch await httpSession.send(request) {
        case .failed(let cause):
            return .retry(cause: cause)
        case .answered(let status, let loopbackRefused, let data):
            return classifyUploadCommitResponse(status: status, body: data, loopbackRefused: status == 403 && loopbackRefused)
        }
    }

    func abortUpload(uploadID: String, serverURL: String) async -> ImportUploadAbortOutcome {
        guard Self.isSafeUploadID(uploadID),
              let url = URL(string: "\(serverURL)\(Self.uploadsPath)/\(uploadID)") else {
            return .retry(cause: "io-address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.attachLoopbackCapability()
        switch await httpSession.send(request) {
        case .failed(let cause):
            return .retry(cause: cause)
        case .answered(let status, let loopbackRefused, _):
            return classifyUploadAbortResponse(status: status, loopbackRefused: status == 403 && loopbackRefused)
        }
    }

    private static func classify(_ operation: ImportOperation, _ answer: ImportStreamedRequest.Answer) -> ImportOutcome {
        switch answer {
        case .failed(let cause):
            return .retry(cause: cause)
        case .answered(let status, let loopbackRefused, let data):
            return classifyImportResponse(operation, status: status, body: data, loopbackRefused: status == 403 && loopbackRefused)
        }
    }
}

/// Pooled, redirect-refusing, cache-free `URLSession` wrapper for resumable chunks and import control calls.
/// `ImportHTTPSessionDelegate` holds no reference back to `ImportHTTPSession`, so `deinit` cleanly invalidates
/// the underlying `URLSession` without a retain cycle.
private final class ImportHTTPSession: @unchecked Sendable {
    private let session: URLSession
    private let delegate: ImportHTTPSessionDelegate

    init(configuration: URLSessionConfiguration) {
        let delegate = ImportHTTPSessionDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func send(_ request: URLRequest, uploadBody: Data? = nil) async -> ImportStreamedRequest.Answer {
        let state = ImportHTTPSessionDelegate.TaskState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task: URLSessionTask
                if let uploadBody {
                    task = session.uploadTask(with: request, from: uploadBody)
                } else {
                    task = session.dataTask(with: request)
                }
                delegate.start(task: task, state: state) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            delegate.cancel(state: state)
        }
    }
}

private final class ImportHTTPSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    final class TaskState: @unchecked Sendable {
        var task: URLSessionTask?
        var cancelled = false
        var response: HTTPURLResponse?
        var data = Data()
        var finish: ((ImportStreamedRequest.Answer) -> Void)?
    }

    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private static let maximumAnswerBytes = 1024 * 1024

    func start(task: URLSessionTask, state: TaskState, finish: @escaping (ImportStreamedRequest.Answer) -> Void) {
        let alreadyCancelled: Bool = lock.withLock {
            if state.cancelled { return true }
            state.task = task
            state.finish = finish
            states[task.taskIdentifier] = state
            return false
        }
        if alreadyCancelled {
            finish(.failed(cause: "io-cancelled"))
            return
        }
        task.resume()
        let cancelledDuringResume: Bool = lock.withLock { state.cancelled }
        if cancelledDuringResume {
            task.cancel()
        }
    }

    func cancel(state: TaskState) {
        let activeTask: URLSessionTask? = lock.withLock {
            state.cancelled = true
            return state.task
        }
        activeTask?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            states[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over: Bool = lock.withLock {
            guard let state = states[dataTask.taskIdentifier] else { return false }
            state.data.append(chunk)
            return state.data.count > Self.maximumAnswerBytes
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (answer, done): (ImportStreamedRequest.Answer, ((ImportStreamedRequest.Answer) -> Void)?) = lock.withLock {
            guard let state = states.removeValue(forKey: task.taskIdentifier) else {
                return (.failed(cause: "io-unknown"), nil)
            }
            let finish = state.finish
            state.finish = nil
            state.task = nil
            if let response = state.response, error == nil {
                let marked = response.value(forHTTPHeaderField: "X-SPL-Loopback-Refused") != nil
                return (.answered(status: response.statusCode, loopbackRefused: marked, data: state.data), finish)
            }
            if state.cancelled {
                return (.failed(cause: "io-cancelled"), finish)
            }
            if let response = state.response {
                let marked = response.value(forHTTPHeaderField: "X-SPL-Loopback-Refused") != nil
                return (.answered(status: response.statusCode, loopbackRefused: marked, data: state.data), finish)
            }
            let code = (error as? URLError)?.code.rawValue ?? -1
            return (.failed(cause: "io-urlerror\(code < 0 ? "-" : "")\(abs(code))"), finish)
        }
        done?(answer)
    }
}

/// The save's body: prefix, the file read in chunks, suffix. Its length is known before it starts.
struct ImportMultipartBody: Sendable {
    let prefix: Data
    let suffix: Data
    let fileURL: URL
    let fileLength: Int64
    var contentLength: Int64 { Int64(prefix.count) + fileLength + Int64(suffix.count) }

    init(boundary: String, item: ImportItemDescriptor) {
        let filename = importWireFilename(item.displayName)
        let mime = item.mime.filter { $0 != "\r" && $0 != "\n" }
        var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"client_item_id\"\r\n\r\n\(item.id)\r\n"
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"imported_via\"\r\n\r\n\(ImportLiveTransport.importedVia)\r\n"
        if let handoff = item.handoff {
            func field(_ name: String, _ value: String) -> String {
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            }
            head += field("area", handoff.area)
            if !ImportHandoff.unhintedAreas.contains(handoff.area) { head += field("source_hint", handoff.area) }
            head += field("context", handoff.context)
        }
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
        if !mime.isEmpty { head += "Content-Type: \(mime)\r\n" }
        head += "\r\n"
        prefix = Data(head.utf8)
        suffix = Data("\r\n--\(boundary)--\r\n".utf8)
        fileURL = item.payloadURL
        fileLength = item.size
    }

    /// Writes the whole body to `write`, reading the file through `read` in chunks of at most
    /// `chunk` bytes. Stops, returning false, when a write fails or the file ends early.
    func stream(
        chunk: Int = ImportLiveTransport.chunkSize,
        read: (FileHandle, Int) throws -> Data = { handle, count in try handle.read(upToCount: count) ?? Data() },
        write: (Data) -> Bool
    ) -> Bool {
        guard write(prefix) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        var sent: Int64 = 0
        while sent < fileLength {
            let want = Int(min(Int64(chunk), fileLength - sent))
            guard let data = try? read(handle, want), !data.isEmpty, data.count <= want else { return false }
            guard write(data) else { return false }
            sent += Int64(data.count)
        }
        return write(suffix)
    }
}

/// One request through its own session, with a streamed body when it has one. The delegate hands
/// over the body stream once; a second ask for one fails the request, which the caller retries.
final class ImportStreamedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Answer: Sendable {
        /// `loopbackRefused`: the answer carries this Mac's loopback proxy's own refusal mark.
        case answered(status: Int, loopbackRefused: Bool, data: Data)
        case failed(cause: String)
    }

    private let lock = NSLock()
    private let body: ImportMultipartBody?
    private var input: InputStream?
    private var task: URLSessionTask?
    private var cancelled = false
    private var handedOver = false
    private var data = Data()
    private var response: HTTPURLResponse?
    private var finish: ((Answer) -> Void)?
    private static let maximumAnswerBytes = 1024 * 1024

    private init(body: ImportMultipartBody?) {
        self.body = body
    }

    static func send(_ request: URLRequest, body: ImportMultipartBody?, configuration: URLSessionConfiguration? = nil) async -> Answer {
        let delegate = ImportStreamedRequest(body: body)
        let config = configuration ?? UploadClient.defaultSessionConfiguration()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task: URLSessionTask
                if body != nil {
                    task = session.uploadTask(withStreamedRequest: request)
                } else {
                    task = session.dataTask(with: request)
                }
                delegate.start(task: task) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func start(task: URLSessionTask, finish: @escaping (Answer) -> Void) {
        let alreadyCancelled: Bool = lock.withLock {
            if cancelled { return true }
            self.task = task
            self.finish = finish
            return false
        }
        if alreadyCancelled {
            finish(.failed(cause: "io-cancelled"))
            return
        }
        task.resume()
        let cancelledDuringResume: Bool = lock.withLock { cancelled }
        if cancelledDuringResume {
            task.cancel()
        }
    }

    private func cancel() {
        let activeTask: URLSessionTask? = lock.withLock {
            cancelled = true
            return task
        }
        activeTask?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        let proceed: Bool = lock.withLock {
            defer { handedOver = true }
            return !handedOver && !cancelled
        }
        guard proceed, let body else {
            completionHandler(nil)
            return
        }
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: ImportLiveTransport.chunkSize, inputStream: &input, outputStream: &output)
        guard let input, let output else {
            completionHandler(nil)
            return
        }
        let abortedAfterStreams: Bool = lock.withLock {
            if cancelled { return true }
            self.input = input
            return false
        }
        if abortedAfterStreams {
            input.close()
            output.close()
            completionHandler(nil)
            return
        }
        // The writer blocks while the session reads, so it has a thread of its own.
        let box = ImportStreamBox(output)
        let writer = Thread {
            let output = box.stream
            output.open()
            defer { output.close() }
            _ = body.stream { chunk in
                var offset = 0
                while offset < chunk.count {
                    let written = chunk.withUnsafeBytes { raw -> Int in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                        return output.write(base + offset, maxLength: chunk.count - offset)
                    }
                    if written <= 0 { return false }
                    offset += written
                }
                return true
            }
        }
        writer.name = "import-body"
        writer.start()
        completionHandler(input)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { self.response = response as? HTTPURLResponse }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over: Bool = lock.withLock {
            data.append(chunk)
            return data.count > Self.maximumAnswerBytes
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (answer, done): (Answer, ((Answer) -> Void)?) = lock.withLock {
            defer {
                finish = nil
                self.task = nil
                input?.close()
                input = nil
            }
            if let response, error == nil {
                let marked = response.value(forHTTPHeaderField: "X-SPL-Loopback-Refused") != nil
                return (.answered(status: response.statusCode, loopbackRefused: marked, data: data), finish)
            }
            if cancelled {
                return (.failed(cause: "io-cancelled"), finish)
            }
            if let response {
                let marked = response.value(forHTTPHeaderField: "X-SPL-Loopback-Refused") != nil
                return (.answered(status: response.statusCode, loopbackRefused: marked, data: data), finish)
            }
            let code = (error as? URLError)?.code.rawValue ?? -1
            return (.failed(cause: "io-urlerror\(code < 0 ? "-" : "")\(abs(code))"), finish)
        }
        done?(answer)
    }
}

/// Hands an output stream to the one thread that writes it.
private final class ImportStreamBox: @unchecked Sendable {
    let stream: OutputStream
    init(_ stream: OutputStream) { self.stream = stream }
}
