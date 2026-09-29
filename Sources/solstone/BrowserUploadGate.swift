// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation

public struct BrowserUploadPermit: Sendable, Equatable {
    public let generation: String
    public let identityToken: String

    public init(generation: String, identityToken: String) {
        self.generation = generation
        self.identityToken = identityToken
    }
}

public final class BrowserUploadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let store: BrowserIntakeStore
    private var activeReadersCount: Int = 0
    private var isCancelled: Bool = false

    public init(store: BrowserIntakeStore) {
        self.store = store
    }

    public func currentPermit() -> BrowserUploadPermit? {
        condition.lock()
        defer { condition.unlock() }
        guard !isCancelled else { return nil }
        guard let generation = store.getActiveGeneration(),
              let token = store.getActiveIdentityToken() else {
            return nil
        }
        return BrowserUploadPermit(generation: generation, identityToken: token)
    }

    public func isPermitActive(_ permit: BrowserUploadPermit) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !isCancelled else { return false }
        guard let currentGeneration = store.getActiveGeneration(),
              let currentToken = store.getActiveIdentityToken() else {
            return false
        }
        return currentGeneration == permit.generation && currentToken == permit.identityToken
    }

    public func enterBodyRead(permit: BrowserUploadPermit) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if isCancelled { return false }
        guard let currentGeneration = store.getActiveGeneration(),
              let currentToken = store.getActiveIdentityToken(),
              currentGeneration == permit.generation,
              currentToken == permit.identityToken else {
            return false
        }
        activeReadersCount += 1
        return true
    }

    public func leaveBodyRead() {
        condition.lock()
        activeReadersCount -= 1
        if activeReadersCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    /// Blocks until in-flight body reads finish. New reads stay closed until
    /// `resumeReaders()` after the replacement epoch is durable.
    public func cancelInFlightAndWait() {
        condition.lock()
        isCancelled = true
        while activeReadersCount > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    public func resumeReaders() {
        condition.lock()
        isCancelled = false
        condition.unlock()
    }

    public func readBodyData(fileURL: URL, permit: BrowserUploadPermit) -> Data {
        guard enterBodyRead(permit: permit) else {
            return Data()
        }
        defer { leaveBodyRead() }
        guard isPermitActive(permit) else {
            return Data()
        }
        return (try? Data(contentsOf: fileURL)) ?? Data()
    }
}

#endif
