// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation

final class BrowserIntakeRouteState: @unchecked Sendable {
    private let lock = NSLock()
    private var route: String?

    func update(_ route: String?) -> Bool {
        lock.withLock {
            guard !BrowserOpaqueString.equals(self.route, route) else { return false }
            self.route = route
            return true
        }
    }

    func matches(_ route: String) -> Bool {
        lock.withLock { BrowserOpaqueString.equals(self.route, route) }
    }
}

public struct BrowserUploadPermit: Sendable, Equatable {
    public let generation: String
    public let identityToken: String

    public init(generation: String, identityToken: String) {
        self.generation = generation
        self.identityToken = identityToken
    }
}

public final class BrowserUploadLease: @unchecked Sendable {
    private weak var gate: BrowserUploadGate?
    private let routeCheck: @Sendable () -> Bool
    fileprivate let id: UUID
    fileprivate let permit: BrowserUploadPermit
    let periodId: String

    fileprivate init(gate: BrowserUploadGate, id: UUID, permit: BrowserUploadPermit, periodId: String, routeCheck: @escaping @Sendable () -> Bool) {
        self.gate = gate
        self.id = id
        self.permit = permit
        self.periodId = periodId
        self.routeCheck = routeCheck
    }

    public func isValid() -> Bool {
        (gate?.isLeaseActive(id: id, permit: permit) ?? false) && routeCheck()
    }

    public func onInvalidate(_ cancel: @escaping @Sendable () -> Void) {
        gate?.setCancellationHandler(cancel, for: id)
    }
}

public final class BrowserUploadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let store: BrowserIntakeStore
    private var isCancelled = false
    private var activeLeaseID: UUID?
    private var cancellationHandler: (@Sendable () -> Void)?

    public init(store: BrowserIntakeStore) {
        self.store = store
    }

    public func currentPermit() -> BrowserUploadPermit? {
        lock.withLock {
            guard !isCancelled,
                  !store.storeIsFailed(),
                  let generation = store.getActiveGeneration(),
                  let token = store.getActiveIdentityToken() else {
                return nil
            }
            return BrowserUploadPermit(generation: generation, identityToken: token)
        }
    }

    public func makeLease(permit: BrowserUploadPermit, periodId: String, routeCheck: @escaping @Sendable () -> Bool = { true }) -> BrowserUploadLease? {
        lock.withLock {
            guard !isCancelled,
                  !store.storeIsFailed(),
                  store.getActiveGeneration().map({ BrowserOpaqueString.equals($0, permit.generation) }) == true,
                  store.getActiveIdentityToken().map({ BrowserOpaqueString.equals($0, permit.identityToken) }) == true else {
                return nil
            }
            let id = UUID()
            activeLeaseID = id
            cancellationHandler = nil
            return BrowserUploadLease(gate: self, id: id, permit: permit, periodId: periodId, routeCheck: routeCheck)
        }
    }

    public func isPermitActive(_ permit: BrowserUploadPermit) -> Bool {
        lock.withLock {
            !isCancelled && !store.storeIsFailed() && store.getActiveGeneration().map({ BrowserOpaqueString.equals($0, permit.generation) }) == true && store.getActiveIdentityToken().map({ BrowserOpaqueString.equals($0, permit.identityToken) }) == true
        }
    }

    fileprivate func isLeaseActive(id: UUID, permit: BrowserUploadPermit) -> Bool {
        lock.withLock {
            !isCancelled && !store.storeIsFailed() && activeLeaseID == id && store.getActiveGeneration().map({ BrowserOpaqueString.equals($0, permit.generation) }) == true && store.getActiveIdentityToken().map({ BrowserOpaqueString.equals($0, permit.identityToken) }) == true
        }
    }

    fileprivate func setCancellationHandler(_ handler: @escaping @Sendable () -> Void, for id: UUID) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !isCancelled, activeLeaseID == id else { return true }
            cancellationHandler = handler
            return false
        }
        if shouldCancel { handler() }
    }

    public func invalidateCurrentLease() {
        let cancel = lock.withLock { () -> (@Sendable () -> Void)? in
            isCancelled = true
            activeLeaseID = nil
            defer { cancellationHandler = nil }
            return cancellationHandler
        }
        cancel?()
    }

    public func resumeReaders() {
        lock.withLock { isCancelled = false }
    }

    public func readBodyData(fileURL: URL, permit: BrowserUploadPermit) -> Data {
        guard isPermitActive(permit) else { return Data() }
        return (try? Data(contentsOf: fileURL)) ?? Data()
    }
}

#endif
