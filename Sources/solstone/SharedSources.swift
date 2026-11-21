// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

struct SharedSourceRoute: Equatable, Sendable {
    let identity: String
    let port: Int
    let incarnation: UInt64
    var base: String { "http://127.0.0.1:\(port)" }
}

struct JournalSystemStatus: Decodable, Sendable {
    let capabilities: [String]?
    let sources_rev: String?
}

protocol SharedSourceTransport: Sendable {
    func systemStatus(serverURL: String) async throws -> JournalSystemStatus
    func declareSources(_ sources: [SourceDeclaration], serverURL: String) async throws
    func knownSources(serverURL: String) async throws -> SharedSourceSnapshot
}

/// One writer per running app. A changing local configuration replaces the desired array,
/// and a reply from a retired connection cannot publish to the next one.
@MainActor @Observable
final class SharedSources {
    private struct Cache: Codable {
        let identity: String
        let snapshot: SharedSourceSnapshot
        let fetched: Date
    }
    private static let cacheKey = "pairedSharedSources"
    private static let revokedKey = "revokedSharedSourcePairing"
    private let defaults: UserDefaults
    private let transport: any SharedSourceTransport
    private let now: () -> Date
    private var cache: Cache?
    private var revoked: String?
    @ObservationIgnored var currentRoute: () -> SharedSourceRoute? = { nil }
    private var route: SharedSourceRoute?
    private var desired: [SourceDeclaration] = []
    private var accepted: [SourceDeclaration]?
    private var rejected: [SourceDeclaration]?
    private var capability: Bool?
    private var revision: String?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(5)
    private var checkStatus = false
    private var forceRead = false
    private var pending = false
    private var worker: Task<Void, Never>?
    private var statusFlight: (SharedSourceRoute, UUID, Task<JournalSystemStatus, Error>)?

    init(defaults: UserDefaults = .standard, transport: any SharedSourceTransport = UploadClient(),
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.transport = transport
        self.now = now
        cache = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        revoked = defaults.string(forKey: Self.revokedKey)
    }

    func devices(for identity: String?) -> [SharedSourceDevice] {
        guard let identity, identity != revoked, let cache, cache.identity == identity else { return [] }
        return cache.snapshot.otherObsidianDevices
    }

    func wipe() {
        dropCache()
        revoked = nil
        defaults.removeObject(forKey: Self.revokedKey)
        resetRoute(nil)
    }

    func revoke(identity: String) {
        dropCache()
        revoked = identity
        defaults.set(identity, forKey: Self.revokedKey)
        cancelRetry()
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryDelay = .seconds(5)
    }

    /// Only a failed exchange arms a retry. Successful and unsupported journals stay idle.
    private func retry(_ target: SharedSourceRoute) {
        guard retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(.seconds(300), retryDelay * 2)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, valid(target) else { return }
            retryTask = nil
            checkStatus = true
            wake()
        }
    }

    private func dropCache() {
        cache = nil
        defaults.removeObject(forKey: Self.cacheKey)
    }

    private func resetRoute(_ newRoute: SharedSourceRoute?) {
        route = newRoute
        cancelRetry()
        statusFlight?.2.cancel()
        statusFlight = nil
        accepted = nil
        rejected = nil
        capability = nil
        revision = nil
        checkStatus = newRoute != nil
        forceRead = false
        pending = false
    }

    func update(identity: String?, route next: SharedSourceRoute?, sources: [SourceDeclaration]) {
        if let identity, let cache, cache.identity != identity { dropCache() }
        if let identity, let revoked, revoked != identity {
            self.revoked = nil
            defaults.removeObject(forKey: Self.revokedKey)
        }
        let routeChanged = route != next
        let sourcesChanged = desired != sources
        if routeChanged { resetRoute(next) }
        if sourcesChanged {
            desired = sources
            rejected = nil
        }
        if routeChanged || sourcesChanged { wake() }
    }

    func opened(detail: Bool) {
        guard route != nil else { return }
        checkStatus = true
        forceRead = forceRead || detail || (cache.map { now().timeIntervalSince($0.fetched) > 300 } ?? true)
        wake()
    }

    private func valid(_ candidate: SharedSourceRoute) -> Bool {
        route == candidate && currentRoute() == candidate && revoked != candidate.identity
    }

    private func wake() {
        guard let route, valid(route) else { return }
        pending = true
        if worker == nil {
            worker = Task {
                while pending, let route = self.route, valid(route) {
                    pending = false
                    await pass(route)
                }
                worker = nil
            }
        }
    }

    func waitForPendingWork() async { await worker?.value }

    private func status(_ target: SharedSourceRoute) async throws -> JournalSystemStatus {
        if let flight = statusFlight, flight.0 == target { return try await flight.2.value }
        let id = UUID()
        let task = Task { try await transport.systemStatus(serverURL: target.base) }
        statusFlight = (target, id, task)
        defer { if statusFlight?.1 == id { statusFlight = nil } }
        return try await task.value
    }

    /// Folder workers already read this endpoint. Use their reply even when no window is open.
    func folderCapabilities(serverURL: String) async throws -> [String] {
        guard let target = currentRoute(), target.base == serverURL, valid(target) else {
            // Folder sync owns its own admission and must work against older journals.
            return try await transport.systemStatus(serverURL: serverURL).capabilities ?? []
        }
        do {
            let response = try await status(target)
            guard valid(target) else { throw CancellationError() }
            record(response)
            if capability == true && (revision != cache?.snapshot.sources_rev || accepted != desired) { wake() }
            return response.capabilities ?? []
        } catch {
            handle(error, target: target)
            throw error
        }
    }

    private func record(_ response: JournalSystemStatus) {
        capability = response.capabilities?.contains("shared_sources") == true
        revision = response.sources_rev
        if capability == false {
            dropCache()
            accepted = nil
            cancelRetry()
        }
    }

    private func pass(_ target: SharedSourceRoute) async {
        let readRegardless = forceRead
        let readStatus = checkStatus || capability == nil
        forceRead = false
        checkStatus = false
        do {
            if readStatus {
                let response = try await status(target)
                guard valid(target) else { return }
                record(response)
            }
            guard valid(target), capability == true else { return }
            if desired != accepted && desired != rejected {
                let sending = desired
                do {
                    try await transport.declareSources(sending, serverURL: target.base)
                    guard valid(target), capability == true else { return }
                    accepted = sending
                } catch UploadError.serverError(let error) where error.statusCode == 400 {
                    guard valid(target) else { return }
                    rejected = sending
                    Logger.upload.error("Journal rejected the local source declaration")
                }
            }
            guard valid(target), capability == true else { return }
            guard readRegardless || cache == nil ||
                    (revision != nil && cache?.snapshot.sources_rev != revision) else {
                cancelRetry()
                return
            }
            let requestedRevision = revision
            let snapshot = try await transport.knownSources(serverURL: target.base)
            guard valid(target), capability == true else { return }
            // A folder worker can learn of a rename, removal or downgrade during this read.
            if revision != requestedRevision && revision != snapshot.sources_rev {
                forceRead = true
                wake()
                return
            }
            let next = Cache(identity: target.identity, snapshot: snapshot, fetched: now())
            defaults.set(try JSONEncoder().encode(next), forKey: Self.cacheKey)
            cache = next
            revision = snapshot.sources_rev
            cancelRetry()
        } catch {
            guard valid(target) else { return }
            forceRead = forceRead || readRegardless
            handle(error, target: target)
        }
    }

    private func handle(_ error: Error, target: SharedSourceRoute) {
        guard valid(target) else { return }
        guard case UploadError.serverError(let refusal) = error else {
            retry(target)
            return
        }
        switch refusal.statusCode {
        case 403:
            revoke(identity: target.identity)
        case 404:
            cancelRetry()
            capability = false
            accepted = nil
            dropCache()
        case 400: Logger.upload.error("Journal rejected a shared source request")
        case 500...599: retry(target)
        default: break
        }
    }
}
