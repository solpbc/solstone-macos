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
    func ageStamp() -> BrowserAgeStamp?
}

public extension BrowserIntakeClock {
    func ageStamp() -> BrowserAgeStamp? { BrowserAgeStamp.current() }
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
    private var stopped = false
    private var epoch: UInt64 = 0
    private var deliveryTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var observerTokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(store: BrowserIntakeStore, authority: BrowserIntakeAuthority, gate: BrowserUploadGate) {
        self.store = store
        self.authority = authority
        self.gate = gate
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
                observerTokens.removeAll()
            }
            return (deliveryTask, boundaryTask, observerTokens)
        }
        guard let (deliveryTask, boundaryTask, tokens) = resources else { return }

        authority.closeAdmission()
        gate.invalidateCurrentLease()
        store.stopDeliveryProofs()
        deliveryTask?.cancel()
        boundaryTask?.cancel()
        for (center, token) in tokens { center.removeObserver(token) }

        do {
            try authority.stopAndFinalize()
        } catch {
            store.setStoreFailed(true)
            Logger.storage.error("Browser intake stop finalization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func drain() async {
        let tasks = lock.withLock { (deliveryTask, boundaryTask) }
        await tasks.0?.value
        await tasks.1?.value
    }

    func resumeAfterDrain() -> Bool {
        lock.withLock {
            guard stopped else { return false }
            deliveryTask = nil
            boundaryTask = nil
            epoch &+= 1
            stopped = false
            return true
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
    private var intakeEnabled = true
    private var statusChangeRunning = false
    private var statusChangePending = false
    private var statusChangeHandler: (@Sendable () async -> Void)?

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
        self.stopController = BrowserIntakeStopController(store: store, authority: authority, gate: gate)
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
        let store = try BrowserIntakeStore(rootURL: spoolRoot, projection: projection, ioInjector: ioInjector, ageClock: { clock.ageStamp() })
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
            nowMs: { BrowserAgeStamp.wallMilliseconds(clock.wallNow()) },
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
        routeState.setOnChange { [weak gate, weak owner, weak routeState] in
            guard let gate else { return }
            gate.invalidateCurrentLease()
            gate.resumeReaders()
            guard let permit = gate.currentPermit(), routeState?.snapshot(for: permit) != nil else { return }
            Task { await owner?.scheduleDelivery() }
        }
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
        let runEpoch = stopController.currentEpoch()
        started = true
        let workspaceCenter = await MainActor.run { NSWorkspace.shared.notificationCenter }
        guard stopController.isActive(epoch: runEpoch) else { return }
        observeLifecycle(workspaceCenter: workspaceCenter)
        guard !stopController.isStopped() else { return }
        authority.poll(now: clock.wallNow())
        startBoundaryWaiter()
        scheduleDelivery()
    }

    private var admissionOpen: @Sendable () -> Bool = { true }

    public func setAdmissionOpen(_ predicate: @escaping @Sendable () -> Bool) {
        admissionOpen = predicate
    }

    public func accept(bytes: Data, direction: String) -> BrowserIntakeAcceptResult {
        accept(decoded: BrowserPayloadDecoder.decode(bytes: bytes, direction: direction, projection: authority.projection))
    }

    public func accept(decoded: BrowserDecodeResult, sessionIsCurrent: @Sendable () -> Bool = { true }) -> BrowserIntakeAcceptResult {
        guard admissionOpen() else { return .refusal(BrowserIntakeLocalRefusal(code: "shutdown")) }
        guard sessionIsCurrent() else { return .refusal(BrowserIntakeLocalRefusal(code: "shutdown")) }
        guard started, !stopController.isStopped() else { return .refusal(BrowserIntakeLocalRefusal(code: "intake_off")) }
        do {
            let reply = try authority.accept(decoded: decoded, admitNewBatches: intakeEnabled, sessionIsCurrent: sessionIsCurrent)
            if reply["type"] as? String == "refused" {
                return .refusal(BrowserIntakeLocalRefusal(
                    code: reply["code"] as? String ?? "malformed",
                    field: reply["field"] as? String
                ))
            }
            let projected = projectIntakePreference(in: reply)
            let message = try BrowserPayloadDecoder.validatedHostMessage(projected, projection: authority.projection)
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

    public func setIntakeEnabled(_ enabled: Bool) {
        intakeEnabled = enabled
        notifyStatusChanged()
    }

    public func isIntakeEnabled() -> Bool {
        intakeEnabled
    }

    public func setStatusChangeHandler(_ handler: (@Sendable () async -> Void)?) {
        statusChangeHandler = handler
    }

    public func projectedStatus() -> [String: Any] {
        projectIntakePreference(in: authority.status())
    }

    public func projectedStateData() -> Data? {
        let status = projectedStatus()
        guard let message = try? BrowserPayloadDecoder.validatedHostMessage(status, projection: authority.projection) else {
            return nil
        }
        return BrowserPayloadDecoder.encodeHostToExtension(message)
    }

    public func currentHostProjection() -> (facts: BrowserHostOwnerFacts, state: Data?) {
        let status = projectedStatus()
        let facts = BrowserHostOwnerFacts(status: status, intakeEnabled: intakeEnabled)
        let state = (try? BrowserPayloadDecoder.validatedHostMessage(status, projection: authority.projection))
            .map { BrowserPayloadDecoder.encodeHostToExtension($0) }
        return (facts, state)
    }

    public func currentFacts() -> BrowserHostOwnerFacts {
        BrowserHostOwnerFacts(status: projectedStatus(), intakeEnabled: intakeEnabled)
    }

    static func projectingIntake(_ enabled: Bool, status: [String: Any]) -> [String: Any] {
        guard !enabled,
              let capture = status["capture"] as? String,
              capture == "permitted" || capture == "paused" else { return status }
        var projected = status
        projected["capture"] = "intake_off"
        return projected
    }

    private func projectIntakePreference(in status: [String: Any]) -> [String: Any] {
        Self.projectingIntake(intakeEnabled, status: status)
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

    nonisolated func bindCredentials(_ credentialStore: PairingCredentialStore) {
        credentialStore.installBrowserHooks(beforeMutation: { [weak self] newToken in
            guard let self else { return }
            try self.credentialWillChange(identityToken: newToken)
        }, afterMutation: { [weak self] token in
            guard let self else { return }
            do {
                try self.credentialDidChange(identityToken: token)
            } catch {
                Logger.storage.error("Browser intake epoch publication failed")
            }
        }, afterLoad: { [weak self] token in
            guard let self else { return }
            do {
                try self.credentialReloaded(identityToken: token)
            } catch {
                Logger.storage.error("Browser intake credential reload rejected: \(error.localizedDescription, privacy: .public)")
            }
        })

    }

    public nonisolated func credentialWillChange(identityToken: String?) throws {
        guard !stopController.isStopped() else { return }
        authority.closeAdmission()
        gate.invalidateCurrentLease()
        store.closeDeliveryProofs()
        try authority.reconcileIdentity(identityToken, mode: .replace)
    }

    public nonisolated func credentialDidChange(identityToken: String?) throws {
        guard !stopController.isStopped() else { return }
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
        guard !stopController.isStopped() else { return }
        authority.closeAdmission()
        gate.invalidateCurrentLease()
        store.closeDeliveryProofs()
        try authority.reconcileIdentity(identityToken, mode: .reload)
        if authority.isAdmissionOpen() { gate.resumeReaders() }
    }

    public nonisolated func stop() { stopController.stop() }

    public func stopAndDrain() async {
        stop()
        await stopController.drain()
    }

    public func resumeAfterFailedUpdate(credentialSnapshot: BrowserCredentialSnapshot, paused: Bool) async {
        guard stopController.isStopped() else { return }
        await stopController.drain()
        guard stopController.isStopped(), !store.storeIsFailed() else { return }
        store.resumeDeliveryAfterDrain()
        authority.resumeAfterDrain()
        do {
            let currentZone = clock.timeZone()
            try authority.setTimeZone(currentZone)
            timeZone = currentZone
            try authority.reconcileIdentity(credentialSnapshot.identityToken, mode: .reload)
            authority.setPaused(paused)
            guard stopController.resumeAfterDrain() else { return }
            deliveryRunning = false
            deliveryPending = false
            started = false
            gate.resumeReaders()
            await start()
        } catch {
            store.stopDeliveryProofs()
            authority.closeAdmission()
            Logger.storage.error("Browser intake update recovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

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
        notifyStatusChanged()
        if deliveryPending && !stopController.isStopped() {
            deliveryPending = false
            scheduleDelivery()
        }
    }

    private func notifyStatusChanged() {
        guard let handler = statusChangeHandler else { return }
        if statusChangeRunning {
            statusChangePending = true
            return
        }
        statusChangeRunning = true
        Task { [weak self] in
            guard let self else { return }
            await self.runStatusChangeLoop(handler)
        }
    }

    private func runStatusChangeLoop(_ handler: @escaping @Sendable () async -> Void) async {
        while true {
            statusChangePending = false
            await handler()
            if !statusChangePending {
                statusChangeRunning = false
                return
            }
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
        guard !stopController.isStopped() else { return }
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
        let runEpoch = stopController.currentEpoch()
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
                await self.boundaryDidPass(epoch: runEpoch)
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

    private func boundaryDidPass(epoch: UInt64) {
        guard started, stopController.isActive(epoch: epoch) else { return }
        authority.poll(now: clock.wallNow())
        notifyStatusChanged()
        scheduleDelivery()
    }
}

#endif
