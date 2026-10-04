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
        namesSameConnection(
            serverURL: other.serverURL,
            identityDigest: other.identityDigest,
            pairingGeneration: other.pairingGeneration,
            transportIncarnation: other.transportIncarnation
        )
    }

    func namesSameConnection(serverURL otherURL: String, identityDigest otherDigest: String,
                             pairingGeneration otherPairingGeneration: UInt64,
                             transportIncarnation otherTransportIncarnation: UInt64) -> Bool {
        BrowserOpaqueString.equals(serverURL, otherURL)
            && BrowserOpaqueString.equals(identityDigest, otherDigest)
            && pairingGeneration == otherPairingGeneration
            && transportIncarnation == otherTransportIncarnation
    }
}

final class BrowserIntakeRouteState: @unchecked Sendable {
    private struct AboutRouteKey: Equatable {
        let serverURL: String
        let identityDigest: String
    }

    private let lock = NSLock()
    private var route: BrowserIntakeRouteCapability?
    private var lastAboutRouteKey: AboutRouteKey?
    private var aboutEpochValue: UInt64 = 0
    private var onChange: (@Sendable (BrowserIntakeRouteCapability?, BrowserIntakeRouteCapability?) -> Void)?

    func setOnChange(_ action: @escaping @Sendable (BrowserIntakeRouteCapability?, BrowserIntakeRouteCapability?) -> Void) {
        lock.withLock { onChange = action }
    }

    @discardableResult
    func update(_ route: BrowserIntakeRouteCapability?) -> Bool {
        let result = lock.withLock { () -> (Bool, (@Sendable (BrowserIntakeRouteCapability?, BrowserIntakeRouteCapability?) -> Void)?, BrowserIntakeRouteCapability?, BrowserIntakeRouteCapability?) in
            if let route {
                let key = AboutRouteKey(serverURL: route.serverURL, identityDigest: route.identityDigest)
                if lastAboutRouteKey != key {
                    lastAboutRouteKey = key
                    aboutEpochValue &+= 1
                }
            }
            if let current = self.route, let route, current.namesSameConnection(as: route) { return (false, nil, nil, nil) }
            if self.route == nil && route == nil { return (false, nil, nil, nil) }
            let previous = self.route
            self.route = route
            return (true, onChange, previous, route)
        }
        // Notify after releasing the route lock. Leased operations retain their
        // captured route; readers use the new snapshot for their next lease.
        result.1?(result.2, result.3)
        return result.0
    }

    func currentRoute() -> BrowserIntakeRouteCapability? {
        lock.withLock { route }
    }

    func aboutEpoch() -> UInt64 {
        lock.withLock { aboutEpochValue }
    }

    func snapshot(for permit: BrowserUploadPermit) -> BrowserIntakeRouteCapability? {
        guard let captured = lock.withLock({ route }),
              BrowserOpaqueString.equals(captured.identityDigest, permit.identityToken),
              matches(captured) else { return nil }
        return captured
    }

    func matches(_ captured: BrowserIntakeRouteCapability) -> Bool {
        guard captured.credentialIsCurrent(), let current = lock.withLock({ route }) else { return false }
        return captured.id == current.id && captured.namesSameConnection(as: current)
    }
}

public struct BrowserUploadPermit: Sendable, Equatable {
    public let identityToken: String

    public init(identityToken: String) {
        self.identityToken = identityToken
    }
}

public final class BrowserUploadLease: @unchecked Sendable {
    private weak var gate: BrowserUploadGate?
    fileprivate let id: UUID
    fileprivate let permit: BrowserUploadPermit
    let periodId: String
    private let routeCheck: @Sendable () -> Bool

    fileprivate init(gate: BrowserUploadGate, id: UUID, permit: BrowserUploadPermit, periodId: String, routeCheck: @escaping @Sendable () -> Bool) {
        self.routeCheck = routeCheck
        self.gate = gate
        self.id = id
        self.permit = permit
        self.periodId = periodId
    }

    public func isValid() -> Bool {
        gate?.isLeaseActive(id: id, permit: permit) ?? false
    }

    public func mayStart() -> Bool {
        isValid() && (gate?.isPermitActive(permit) ?? false) && routeCheck()
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
        return BrowserOpaqueString.equals(current.identityToken, permit.identityToken)
    }

    public func makeLease(permit: BrowserUploadPermit, periodId: String, routeCheck: @escaping @Sendable () -> Bool = { true }) -> BrowserUploadLease? {
        lock.withLock {
            guard !isCancelled,
                  permitMatchesStore(permit), routeCheck() else {
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
            activeLeaseID == id
        }
    }

    fileprivate func setCancellationHandler(_ handler: @escaping @Sendable () -> Void, for id: UUID) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard activeLeaseID == id else { return true }
            cancellationHandler = handler
            return false
        }
        if shouldCancel { handler() }
    }

    public func invalidateCurrentLease() {
        lock.withLock {
            isCancelled = true
        }
    }

    func cancelCurrentLease() {
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
