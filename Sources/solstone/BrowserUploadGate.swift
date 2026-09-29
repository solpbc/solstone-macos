// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation

struct BrowserIntakeRouteCapability: Sendable {
    let id = UUID()
    let serverURL: String
    let identityDigest: String
    let pairingGeneration: UInt64
    let transportIncarnation: UInt64
    let credentialIsCurrent: @Sendable () -> Bool

    func namesSameConnection(as other: Self) -> Bool {
        BrowserOpaqueString.equals(serverURL, other.serverURL)
            && BrowserOpaqueString.equals(identityDigest, other.identityDigest)
            && pairingGeneration == other.pairingGeneration
            && transportIncarnation == other.transportIncarnation
    }
}

final class BrowserIntakeRouteState: @unchecked Sendable {
    private let lock = NSLock()
    private var route: BrowserIntakeRouteCapability?
    private var onChange: (@Sendable () -> Void)?

    func setOnChange(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { onChange = action }
    }

    @discardableResult
    func update(_ route: BrowserIntakeRouteCapability?) -> Bool {
        let result = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            if let current = self.route, let route, current.namesSameConnection(as: route) { return (false, nil) }
            if self.route == nil && route == nil { return (false, nil) }
            self.route = route
            return (true, onChange)
        }
        // Invalidate transport tasks outside the route lock. A reader already
        // sees the revoked capability even before cancellation is delivered.
        result.1?()
        return result.0
    }

    func snapshot(for permit: BrowserUploadPermit) -> BrowserIntakeRouteCapability? {
        guard let captured = lock.withLock({ route }),
              BrowserOpaqueString.equals(captured.identityDigest, permit.identityToken),
              matches(captured) else { return nil }
        return captured
    }

    func matches(_ captured: BrowserIntakeRouteCapability) -> Bool {
        guard lock.withLock({ route?.id == captured.id }), captured.credentialIsCurrent() else { return false }
        return lock.withLock { route?.id == captured.id }
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
            guard !isCancelled else { return nil }
            return store.currentDeliveryPermit()
        }
    }

    private func permitMatchesStore(_ permit: BrowserUploadPermit) -> Bool {
        guard let current = store.currentDeliveryPermit() else { return false }
        return BrowserOpaqueString.equals(current.generation, permit.generation)
            && BrowserOpaqueString.equals(current.identityToken, permit.identityToken)
    }

    public func makeLease(permit: BrowserUploadPermit, periodId: String, routeCheck: @escaping @Sendable () -> Bool = { true }) -> BrowserUploadLease? {
        lock.withLock {
            guard !isCancelled,
                  permitMatchesStore(permit) else {
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
            !isCancelled && permitMatchesStore(permit)
        }
    }

    fileprivate func isLeaseActive(id: UUID, permit: BrowserUploadPermit) -> Bool {
        lock.withLock {
            !isCancelled && activeLeaseID == id && permitMatchesStore(permit)
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
