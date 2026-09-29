// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import AppKit
import Foundation
import SolstoneCore
import os

public protocol BrowserIntakeClock: MonotonicClock {
    func wallNow() -> Date
    func timeZone() -> TimeZone
    func sleepUntil(_ date: Date) async throws
}

public struct SystemBrowserIntakeClock: BrowserIntakeClock {
    private let monotonic = SystemMonotonicClock()

    public init() {}

    public func wallNow() -> Date { Date() }
    public func timeZone() -> TimeZone { .current }
    public func now() -> Duration { monotonic.now() }
    public func sleep(for duration: Duration) async { await monotonic.sleep(for: duration) }

    public func sleepUntil(_ date: Date) async throws {
        let delay = date.timeIntervalSince(wallNow())
        if delay > 0 {
            try await Task.sleep(for: .milliseconds(Int64(delay * 1000)))
        }
    }
}

public struct BrowserCredentialSnapshot: Sendable, Equatable {
    public let identityToken: String?

    public init(identityToken: String?) {
        self.identityToken = identityToken
    }
}

public enum BrowserIntakeAcceptResult: Sendable, Equatable {
    case message(Data)
    case refusal(BrowserIntakeLocalRefusal)
}

private final class BrowserIntakeStopController: @unchecked Sendable {
    private let lock = NSLock()
    private let store: BrowserIntakeStore
    private let authority: BrowserIntakeAuthority
    private let gate: BrowserUploadGate
    private let clock: any BrowserIntakeClock
    private var stopped = false
    private var epoch: UInt64 = 0
    private var deliveryTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var observerTokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(store: BrowserIntakeStore, authority: BrowserIntakeAuthority, gate: BrowserUploadGate, clock: any BrowserIntakeClock) {
        self.store = store
        self.authority = authority
        self.gate = gate
        self.clock = clock
    }

    func isStopped() -> Bool { lock.withLock { stopped } }
    func currentEpoch() -> UInt64 { lock.withLock { epoch } }
    func isActive(epoch expected: UInt64) -> Bool { lock.withLock { !stopped && epoch == expected } }

    func setDeliveryTask(_ task: Task<Void, Never>?) {
        let cancel = lock.withLock { () -> Bool in
            guard !stopped else { return true }
            deliveryTask = task
            return false
        }
        if cancel { task?.cancel() }
    }

    func clearDeliveryTask(epoch expected: UInt64) {
        lock.withLock {
            if epoch == expected { deliveryTask = nil }
        }
    }

    func setBoundaryTask(_ task: Task<Void, Never>?) {
        let previous = lock.withLock { () -> Task<Void, Never>? in
            guard !stopped else { return task }
            let previous = boundaryTask
            boundaryTask = task
            return previous
        }
        previous?.cancel()
        if isStopped() { task?.cancel() }
    }

    func setObserverTokens(_ tokens: [(NotificationCenter, NSObjectProtocol)]) {
        let removeImmediately = lock.withLock { () -> Bool in
            guard !stopped else { return true }
            observerTokens.append(contentsOf: tokens)
            return false
        }
        if removeImmediately {
            for (center, token) in tokens { center.removeObserver(token) }
        }
    }

    func stop() {
        let resources = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?, [(NotificationCenter, NSObjectProtocol)])? in
            guard !stopped else { return nil }
            stopped = true
            epoch &+= 1
            defer {
                deliveryTask = nil
                boundaryTask = nil
                observerTokens.removeAll()
            }
            return (deliveryTask, boundaryTask, observerTokens)
        }
        guard let (deliveryTask, boundaryTask, tokens) = resources else { return }

        authority.closeAdmission()
        gate.invalidateCurrentLease()
        deliveryTask?.cancel()
        boundaryTask?.cancel()
        for (center, token) in tokens { center.removeObserver(token) }

        guard let periodId = store.getOpenPeriodId() else { return }
        do {
            try store.finalizePeriod(
                periodId: periodId,
                reason: "owner_stop",
                civilDate: clock.wallNow(),
                timeZone: clock.timeZone(),
                openReplacement: false
            )
        } catch {
            store.setStoreFailed(true)
            Logger.storage.error("Browser intake stop finalization failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

public actor BrowserIntakeOwner {
    public nonisolated let store: BrowserIntakeStore
    public nonisolated let authority: BrowserIntakeAuthority
    public nonisolated let gate: BrowserUploadGate
    public nonisolated let planner: BrowserUploadPlanner
    private nonisolated let stopController: BrowserIntakeStopController

    private let clock: any BrowserIntakeClock
    private let routeState: BrowserIntakeRouteState
    private var timeZone: TimeZone
    private var started = false
    private var deliveryRunning = false
    private var deliveryPending = false

    private init(
        store: BrowserIntakeStore,
        authority: BrowserIntakeAuthority,
        gate: BrowserUploadGate,
        planner: BrowserUploadPlanner,
        clock: any BrowserIntakeClock,
        routeState: BrowserIntakeRouteState
    ) {
        self.store = store
        self.authority = authority
        self.gate = gate
        self.planner = planner
        self.clock = clock
        self.routeState = routeState
        self.timeZone = clock.timeZone()
        self.stopController = BrowserIntakeStopController(store: store, authority: authority, gate: gate, clock: clock)
    }

    static func start(
        spoolRoot: URL,
        projection: BrowserContractProjection,
        credentialSnapshot: BrowserCredentialSnapshot,
        clock: any BrowserIntakeClock = SystemBrowserIntakeClock(),
        transport: any BrowserUploadTransport = UploadClient(),
        routeResolver: HomeBaseURLResolver,
        syncPaused: @escaping @Sendable () async -> Bool = { false },
        ioInjector: BrowserIntakeIOInjector = BrowserIntakeIOInjector(),
        routeState: BrowserIntakeRouteState = BrowserIntakeRouteState()
    ) throws -> BrowserIntakeOwner {
        let store = try BrowserIntakeStore(rootURL: spoolRoot, projection: projection, ioInjector: ioInjector)
        let authority = BrowserIntakeAuthority(
            store: store,
            projection: projection,
            monotonicClock: clock,
            wallClock: { clock.wallNow() },
            timeZone: clock.timeZone()
        )
        let gate = BrowserUploadGate(store: store)
        let planner = BrowserUploadPlanner(
            store: store,
            gate: gate,
            client: transport,
            serverURLProvider: {
                guard case .url(let url) = await routeResolver.resolve() else { return nil }
                return url
            },
            syncPausedProvider: syncPaused,
            nowMs: { UInt64(clock.wallNow().timeIntervalSince1970 * 1000) },
            routeState: routeState
        )
        let owner = BrowserIntakeOwner(
            store: store,
            authority: authority,
            gate: gate,
            planner: planner,
            clock: clock,
            routeState: routeState
        )
        do {
            try authority.reconcileIdentity(credentialSnapshot.identityToken, mode: .reload)
        } catch {
            authority.closeAdmission()
            Logger.storage.error("Browser intake credential reload failed: \(error.localizedDescription, privacy: .public)")
        }
        return owner
    }

    public func start() async {
        guard !started, !stopController.isStopped() else { return }
        started = true
        let workspaceCenter = await MainActor.run { NSWorkspace.shared.notificationCenter }
        observeLifecycle(workspaceCenter: workspaceCenter)
        guard !stopController.isStopped() else { return }
        authority.poll(now: clock.wallNow())
        startBoundaryWaiter()
        scheduleDelivery()
    }

    public func accept(bytes: Data, direction: String) -> BrowserIntakeAcceptResult {
        guard started, !stopController.isStopped() else { return .refusal(BrowserIntakeLocalRefusal(code: "intake_off")) }
        do {
            let reply = try authority.accept(bytes: bytes, direction: direction)
            if reply["type"] as? String == "refused" {
                return .refusal(BrowserIntakeLocalRefusal(
                    code: reply["code"] as? String ?? "malformed",
                    field: reply["field"] as? String
                ))
            }
            let message = try BrowserPayloadDecoder.validatedHostMessage(reply, projection: authority.projection)
            scheduleDelivery()
            return .message(BrowserPayloadDecoder.encodeHostToExtension(message))
        } catch let refusal as BrowserIntakeLocalRefusal {
            return .refusal(refusal)
        } catch {
            store.setStoreFailed(true)
            Logger.storage.error("Browser intake accept failed: \(error.localizedDescription, privacy: .public)")
            return .refusal(BrowserIntakeLocalRefusal(code: "local_io"))
        }
    }

    public func scheduleDelivery() {
        guard started, !stopController.isStopped() else { return }
        if deliveryRunning {
            deliveryPending = true
            return
        }
        deliveryRunning = true
        let runEpoch = stopController.currentEpoch()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDelivery(epoch: runEpoch)
        }
        stopController.setDeliveryTask(task)
    }

    public func updateRoute(_ route: ResolvedHomeBase) {
        let value: String?
        if case .url(let url) = route { value = url } else { value = nil }
        if routeState.update(value) {
            gate.invalidateCurrentLease()
            gate.resumeReaders()
        }
        if value != nil { scheduleDelivery() }
    }

    public nonisolated func credentialWillChange(identityToken: String?) throws {
        authority.closeAdmission()
        gate.invalidateCurrentLease()
        try authority.reconcileIdentity(identityToken, mode: .replace)
    }

    public nonisolated func credentialDidChange(identityToken: String?) throws {
        guard let identityToken else { return }
        do {
            _ = try authority.publishEpoch(identityToken: identityToken)
            authority.reopenAdmission()
            gate.resumeReaders()
        } catch {
            authority.closeAdmission()
            gate.invalidateCurrentLease()
            Logger.storage.error("Browser intake credential replacement failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public nonisolated func credentialReloaded(identityToken: String?) throws {
        authority.closeAdmission()
        gate.invalidateCurrentLease()
        try authority.reconcileIdentity(identityToken, mode: .reload)
        if authority.isAdmissionOpen() { gate.resumeReaders() }
    }

    public nonisolated func stop() { stopController.stop() }

    private func runDelivery(epoch runEpoch: UInt64) async {
        var passes = 0
        repeat {
            guard stopController.isActive(epoch: runEpoch), !Task.isCancelled else { break }
            deliveryPending = false
            await planner.planAndUpload()
            passes += 1
        } while deliveryPending && passes < 2 && stopController.isActive(epoch: runEpoch)

        deliveryRunning = false
        stopController.clearDeliveryTask(epoch: runEpoch)
        if deliveryPending && !stopController.isStopped() {
            deliveryPending = false
            scheduleDelivery()
        }
    }

    private func observeLifecycle(workspaceCenter: NotificationCenter) {
        let wake = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.scheduleDelivery() }
        }
        let timeZoneChange = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.systemTimeZoneChanged() }
        }
        stopController.setObserverTokens([(workspaceCenter, wake), (NotificationCenter.default, timeZoneChange)])
    }

    private func systemTimeZoneChanged() {
        let newZone = clock.timeZone()
        guard newZone != timeZone else { return }
        do {
            try authority.setTimeZone(newZone)
            timeZone = newZone
            startBoundaryWaiter()
            scheduleDelivery()
        } catch {
            store.setStoreFailed(true)
            Logger.storage.error("Browser intake timezone transition failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startBoundaryWaiter() {
        let task = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.stopController.isStopped() else { return }
                let next = await self.nextBoundary(after: clock.wallNow())
                do {
                    try await clock.sleepUntil(next)
                } catch {
                    if Task.isCancelled { return }
                }
                guard !Task.isCancelled else { return }
                await self.boundaryDidPass()
            }
        }
        stopController.setBoundaryTask(task)
    }

    private func nextBoundary(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var next = calendar.dateInterval(of: .minute, for: date)?.end ?? date.addingTimeInterval(60)
        while calendar.component(.minute, from: next) % 5 != 0 {
            next = calendar.dateInterval(of: .minute, for: next)?.end ?? next.addingTimeInterval(60)
        }
        return next
    }

    private func boundaryDidPass() {
        guard started, !stopController.isStopped() else { return }
        authority.poll(now: clock.wallNow())
        scheduleDelivery()
    }
}

#endif
