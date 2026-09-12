// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import AppKit
import Observation
import SolstoneCore
import SPLTunnel
import os

private let splOwnerLog = Logger(subsystem: "app.solstone.observer.spl", category: "owner")

enum TunnelLifecycleState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(localPort: Int, via: TunnelConnectionRoute)
    case error(TunnelLifecycleError)
}

enum TunnelLifecycleError: Error, Sendable, Equatable {
    case revoked
    case loopbackUnavailable
    case keychainUnavailable
    case notEntitled
}

enum JournalConnectionFailureCause: Sendable, Equatable {
    case noRoute
    case revoked
    case notEntitled
    case keychainUnavailable
    case loopbackUnavailable
    case unreachable(String?)
    case mismatch
    case notServing
}

struct JournalConnectionVerdict: Sendable, Equatable {
    let severity: StatusDotSeverity
    let message: String
    let caption: String?
    let axToken: String
    let failureCause: JournalConnectionFailureCause?

    static let neutral = JournalConnectionVerdict(
        severity: .calm,
        message: "not paired",
        caption: nil,
        axToken: PairingConnectionAXState.disconnected.axToken,
        failureCause: nil
    )
}

enum TunnelHealth: Sendable, Equatable {
    case unknown
    case healthy
    case degraded
}

enum PairingRelayAccessStatus: Sendable, Equatable {
    case noPairing
    case available
    case unavailable
}

struct TunnelDeviceTokenRefreshing: Sendable {
    let refreshIfNeeded: @Sendable (StoredPairing, Date) async -> DeviceTokenRefreshResult
    let refreshNow: @Sendable (StoredPairing) async -> DeviceTokenRefreshResult

    static func live(clientInfo: SPLClientInfo = SPLRuntime.clientInfo) -> TunnelDeviceTokenRefreshing {
        let refresher = DeviceTokenRefresher(clientInfo: clientInfo)
        return TunnelDeviceTokenRefreshing(
            refreshIfNeeded: { pairing, now in
                await refresher.refreshIfNeeded(pairing: pairing, now: now)
            },
            refreshNow: { pairing in
                await refresher.refreshNow(pairing: pairing)
            }
        )
    }
}

@MainActor
private final class RelayOutcomeTarget {
    weak var owner: TunnelLifecycleOwner?
}

@MainActor
@Observable
final class TunnelLifecycleOwner {
    private static let probeInterval: Duration = .seconds(30)
    private static let probeTimeout: Duration = .seconds(3)
    private static let degradedProbeInterval: Duration = .seconds(5)
    private static let forcedReconnectDegradedProbeIntervalCap: Duration = .seconds(120)
    private static let silentProbeFailureLimit = 3
    private static let activeInboundProbeFailureLimit = 6
    private static let loopbackRetryDelays: [Duration] = [.milliseconds(100), .milliseconds(300)]
    private static let establishmentRetryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(10), .seconds(30)]
    static let probeWatchdogPolicy = ProbeWatchdogPolicy(
        healthyInterval: probeInterval,
        degradedInterval: degradedProbeInterval,
        silentFailureLimit: silentProbeFailureLimit,
        activeInboundFailureLimit: activeInboundProbeFailureLimit,
        forcedReconnectDegradedIntervalCap: forcedReconnectDegradedProbeIntervalCap,
        jitterRange: 1.0...1.0
    )

    let journalVersion = JournalVersionMetadata()
    private(set) var state: TunnelLifecycleState = .disconnected {
        didSet {
            handleStateTransition(old: oldValue, new: state)
        }
    }
    private(set) var health: TunnelHealth = .unknown {
        didSet {
            updateConnectionVerdict()
        }
    }
    private(set) var hasPersistedPairing = false
    private(set) var supervisorAttemptState: TunnelSupervisorAttemptState = .idle
    private(set) var proxyStartAttemptID: UInt64? = nil
    var isProxyStarting: Bool { proxyStartAttemptID == transportAttemptID }
    private(set) var isBackingOff = false
    private(set) var connectionVerdict: JournalConnectionVerdict = .neutral
    private(set) var isTunnelManaged = false
    private(set) var isPairedHome = false
    private(set) var relayAccessStatus: PairingRelayAccessStatus = .noPairing
    private(set) var liveRelayEligible: Bool = true
    private(set) var pendingDurableClear: (pairingGen: UInt64, accessGen: UInt64)?
    private(set) var transportAttemptID: UInt64 = 0
    private(set) var transportIncarnation: UInt64 = 0

    private var isIntentionallyRetiring = false
    private var rejectedAttemptIDs: Set<UInt64> = []
    private var coalescedReconnectInFlight = false
    private var retainedCandidate: (any TunnelTransporting)?
    private var inFlightEstablishmentBackoffTask: Task<Void, any Error>?
    private var inFlightConnectTask: Task<TunnelTransportConnection, any Error>?

    var localPort: Int? {
        guard case .connected(let localPort, _) = state else {
            return nil
        }
        return localPort
    }

    var cachedPairingIdentity: TunnelPairingIdentity? {
        guard case .loaded(let pairing) = cachedPairingOutcome else {
            return nil
        }
        return TunnelPairingIdentity(
            instanceID: pairing.instanceID,
            fingerprint: pairing.fingerprint
        )
    }

    var sameMachineStoredPairingState: SameMachineStoredPairingState {
        switch loadPairingCached() {
        case .loaded(let pairing):
            return Self.isHomePairing(pairing) ? .pairedHome : .differentHomeHeld
        case .absent:
            return .noneHeld
        case .failed:
            return .unavailable
        }
    }

    var pairingIdentityRead: PairingIdentityRead {
        switch loadPairingCached() {
        case .loaded(let pairing):
            return .found(TunnelPairingIdentity(
                instanceID: pairing.instanceID,
                fingerprint: pairing.fingerprint
            ))
        case .absent:
            return .absent
        case .failed:
            return .failed
        }
    }

    @ObservationIgnored
    let credentialStore: PairingCredentialStore
    @ObservationIgnored
    private let loadPairing: @Sendable () throws -> StoredPairing?
    @ObservationIgnored
    private let savePairing: @Sendable (StoredPairing) throws -> Void
    @ObservationIgnored
    private let deletePairing: @Sendable () throws -> Void
    @ObservationIgnored
    private let tokenRefresher: TunnelDeviceTokenRefreshing
    @ObservationIgnored
    private let makeTransport: @MainActor @Sendable () -> any TunnelTransporting
    @ObservationIgnored
    private let pathMonitor: PathMonitor
    @ObservationIgnored
    private let probe: @Sendable (Int, Duration) async -> Bool
    @ObservationIgnored
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored
    private let now: @Sendable () -> Date

    @ObservationIgnored
    let clientSelfSequencer: JournalClientSelfSequencer
    @ObservationIgnored
    let relayAccessSequencer: JournalRelayAccessSequencer
    @ObservationIgnored
    private let relayOutcomeTarget: RelayOutcomeTarget

    @ObservationIgnored
    private var transport: (any TunnelTransporting)?
    @ObservationIgnored
    private var startTask: Task<Void, Never>?
    @ObservationIgnored
    private var stateObservationTask: Task<Void, Never>?
    @ObservationIgnored
    private var modeObservationTask: Task<Void, Never>?
    @ObservationIgnored
    private var attemptObservationTask: Task<Void, Never>?
    @ObservationIgnored
    private var probeTask: Task<Void, Never>?
    @ObservationIgnored
    private var authRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var authRefreshGeneration = 0
    @ObservationIgnored
    private var pendingReactiveRefresh = false
    @ObservationIgnored
    private var didWakeObserver: NSObjectProtocol?
    @ObservationIgnored
    private var screenUnlockedObserver: NSObjectProtocol?
    @ObservationIgnored
    private var establishedLoopbackPort: Int?
    @ObservationIgnored
    private var establishmentInFlight = false
    @ObservationIgnored
    private var currentPathSignature: NetworkPathSignature?
    @ObservationIgnored
    private var optionalBurstID: UInt64 = 0
    @ObservationIgnored
    private var publishingOptionalBurstID: UInt64?
    @ObservationIgnored
    private var running = false
    @ObservationIgnored
    private var cachedPairingOutcome: PairingLoadOutcome?
    @ObservationIgnored
    private var probeWatchdog = ProbeWatchdog(policy: TunnelLifecycleOwner.probeWatchdogPolicy)

    init(
        keychainStore: SPLKeychainStore = SPLPairingKeychain.store(),
        credentialStore: PairingCredentialStore? = nil,
        loadPairing: (@Sendable () throws -> StoredPairing?)? = nil,
        savePairing: (@Sendable (StoredPairing) throws -> Void)? = nil,
        deletePairing: (@Sendable () throws -> Void)? = nil,
        clientInfo: SPLClientInfo = SPLRuntime.clientInfo,
        tokenRefresher: TunnelDeviceTokenRefreshing? = nil,
        makeTransport: (@MainActor @Sendable () -> any TunnelTransporting)? = nil,
        pathMonitoringSource: (any PathMonitoringSource)? = nil,
        probe: @escaping @Sendable (Int, Duration) async -> Bool = TunnelLifecycleOwner.httpStatusProbe(localPort:timeout:),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        clientSelfSequencer: JournalClientSelfSequencer? = nil,
        relayAccessSequencer: JournalRelayAccessSequencer? = nil,
        loopbackSession: URLSession? = nil,
        optionalJobDeadline: Duration = .seconds(15)
    ) {
        let store = credentialStore ?? PairingCredentialStore(store: keychainStore)
        self.credentialStore = store
        self.loadPairing = loadPairing ?? { try store.load() }
        self.savePairing = savePairing ?? { try store.save($0) }
        self.deletePairing = deletePairing ?? { try store.delete() }
        self.tokenRefresher = tokenRefresher ?? .live(clientInfo: clientInfo)
        self.makeTransport = makeTransport ?? { SPLTunnelTransport(clientInfo: clientInfo) }
        self.pathMonitor = pathMonitoringSource.map { PathMonitor(source: $0) } ?? PathMonitor()
        self.probe = probe
        self.sleep = sleep
        self.now = now

        let session = loopbackSession ?? BoundedLoopbackClient.makeSession()
        let jv = self.journalVersion
        self.clientSelfSequencer = clientSelfSequencer ?? JournalClientSelfSequencer(
            session: session,
            deadline: optionalJobDeadline,
            onJournalMetadataUpdated: { identity, gen, version, name, preserveName, deadline, fence in
                await Task { @MainActor in
                    fence.withCurrent {
                        guard ContinuousClock.now < deadline else { return }
                        jv.applyDirectly(identity: identity, generation: gen, version: version, name: name, markCurrent: true, preserveName: preserveName)
                    }
                }.value
            }
        )

        let target = RelayOutcomeTarget()
        self.relayOutcomeTarget = target
        if let relayAccessSequencer {
            self.relayAccessSequencer = relayAccessSequencer
        } else {
            self.relayAccessSequencer = JournalRelayAccessSequencer(
                credentialStore: store,
                session: session,
                deadline: optionalJobDeadline,
                now: now,
                onOutcome: { [weak target] outcome in
                    await Task { @MainActor in
                        await target?.owner?.handleRelayAccessOutcome(outcome)
                    }.value
                }
            )
        }
        target.owner = self

        refreshTunnelManagedFromStoredPairing()
    }

    static func dormantForSnapshot(
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLPairingKeychain.store().load() }
    ) -> TunnelLifecycleOwner {
        TunnelLifecycleOwner(loadPairing: loadPairing, pathMonitoringSource: NoopPathMonitoringSource())
    }

    func start() {
        guard !running else {
            return
        }
        running = true
        refreshTunnelManagedFromStoredPairing()
        state = .disconnected
        health = .unknown
        installWakeUnlockObservers()
        startPathMonitor()
        startTask = Task { @MainActor [weak self] in
            await self?.connectFromStoredPairing()
        }
    }

    func stop() async {
        running = false
        transportAttemptID &+= 1
        let stoppingAttempt = transportAttemptID
        removeWakeUnlockObservers()
        startTask?.cancel()
        startTask = nil
        cancelReactiveTokenRefresh()
        pathMonitor.stop()
        currentPathSignature = nil
        await clientSelfSequencer.cancel()
        await relayAccessSequencer.cancel()
        guard !running, transportAttemptID == stoppingAttempt else { return }
        await disconnectCurrentTransport()
        guard !running, transportAttemptID == stoppingAttempt else { return }
        state = .disconnected
        health = .unknown
    }

    func beginProxyStart(attempt: UInt64) {
        guard attempt == transportAttemptID else { return }
        proxyStartAttemptID = attempt
        updateConnectionVerdict()
    }

    func endProxyStart(attempt: UInt64) {
        guard proxyStartAttemptID == attempt else { return }
        proxyStartAttemptID = nil
        updateConnectionVerdict()
    }

    func reevaluatePairing() async {
        transportAttemptID &+= 1
        journalVersion.clear()
        invalidatePairingCache()
        liveRelayEligible = true
        pendingDurableClear = nil
        refreshTunnelManagedFromStoredPairing()
        guard running else {
            return
        }

        let previous = startTask
        previous?.cancel()
        cancelReactiveTokenRefresh()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clientSelfSequencer.cancel()
            await self.relayAccessSequencer.cancel()
            await previous?.value
            guard self.running, !Task.isCancelled else { return }
            let attempt = self.transportAttemptID
            await self.disconnectCurrentTransport()
            guard self.running, !Task.isCancelled, self.transportAttemptID == attempt else { return }
            await self.connectFromStoredPairing()
        }
    }

    public func requestCoalescedReconnect() async {
        if let transport {
            await transport.requestReconnect()
            return
        }

        guard running else { return }
        guard !coalescedReconnectInFlight else { return }
        coalescedReconnectInFlight = true

        if establishmentInFlight {
            if inFlightEstablishmentBackoffTask != nil {
                inFlightEstablishmentBackoffTask?.cancel()
                inFlightEstablishmentBackoffTask = nil
            } else if inFlightConnectTask != nil {
                let candidate = retainedCandidate
                retainedCandidate = nil
                rejectedAttemptIDs.insert(transportAttemptID)
                transportAttemptID &+= 1
                inFlightConnectTask?.cancel()
                Task { @MainActor in
                    await candidate?.disconnect()
                }
            }
        } else {
            startTask = Task { @MainActor [weak self] in
                await self?.connect()
            }
        }
    }

    public func retryRevokedPairingRetirement() async {
        let (pGen, aGen) = credentialStore.currentGenerations()
        await retirePairingAndFailRevoked(expectedPairing: pGen, expectedAccess: aGen)
    }

    func handleWakeOrUnlock() async {
        guard running,
              case .connected(let localPort, _) = state
        else {
            return
        }

        let succeeded = await probe(localPort, Self.probeTimeout)
        if succeeded {
            health = .healthy
            splOwnerLog.notice("wake probe ok local_port=\(localPort, privacy: .public)")
            return
        }

        health = .degraded
        splOwnerLog.notice("wake probe failed local_port=\(localPort, privacy: .public) reconnect=true")
        await transport?.requestReconnect()
    }

    private func handleStateTransition(old: TunnelLifecycleState, new: TunnelLifecycleState) {
        updateConnectionVerdict()
        if case .connected(let port, _) = new {
            journalVersion.adoptConnectedPort(port)
            if case .connected(let oldPort, let oldVia) = old, oldPort == port, case .connected(_, let newVia) = new, oldVia == newVia {
                return
            }

            if let pending = pendingDurableClear {
                let (pGen, aGen) = credentialStore.currentGenerations()
                if pending.pairingGen == pGen && pending.accessGen == aGen {
                    if let (cleared, _) = try? credentialStore.clearRelayAccess(expectedPairingGen: pGen, expectedAccessGen: aGen) {
                        pendingDurableClear = nil
                        setCachedPairingOutcome(.loaded(cleared))
                    }
                } else {
                    pendingDurableClear = nil
                }
            }

            let incarnation = transportIncarnation
            let publicationBurst = publishingOptionalBurstID
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.running, self.transportIncarnation == incarnation, self.localPort == port,
                      let pairing = self.currentStoredPairing() else { return }
                if publicationBurst == nil { self.optionalBurstID &+= 1 }
                let burst = publicationBurst ?? self.optionalBurstID
                let (pGen, aGen) = self.credentialStore.currentGenerations()
                if let identity = journalVersionMetadataIdentity(for: pairing) {
                    await self.clientSelfSequencer.enqueue(
                        target: .init(localPort: port, identity: identity, pairingGeneration: pGen,
                                      metadataGeneration: self.journalVersion.currentGeneration()),
                        burstID: burst
                    )
                }
                await self.relayAccessSequencer.enqueue(
                    target: .init(localPort: port, instanceID: pairing.instanceID,
                                  pairingGeneration: pGen, accessMutationGeneration: aGen, transportAttempt: self.transportAttemptID),
                    burstID: burst
                )
            }
        } else {
            journalVersion.disconnected()
        }
    }

    func currentStoredPairing() -> StoredPairing? {
        if case .loaded(let pairing) = cachedPairingOutcome {
            return pairing
        }
        return try? loadPairing()
    }

    func handleRelayAccessOutcome(_ outcome: JournalRelayAccessSequencer.AccessUpdateOutcome) async {
        guard running, !Task.isCancelled else { return }
        let (currentPairingGen, currentAccessGen) = credentialStore.currentGenerations()

        switch outcome {
        case .received(let data, let target, let deadline, let burstID):
            guard credentialStore.matches(pairing: target.pairingGeneration, access: target.accessMutationGeneration),
                  target.transportAttempt == nil || target.transportAttempt == transportAttemptID,
                  ContinuousClock.now < deadline,
                  let pairing = currentStoredPairing(), pairing.instanceID == target.instanceID,
                  let status = try? RelayAccessValidation.decode(data, expectedInstanceID: pairing.instanceID, now: now())
            else { return }
            switch status {
            case .ready(let ready):
                do {
                    let (persisted, _) = try credentialStore.updateRelayAccess(
                        expectedPairingGen: target.pairingGeneration,
                        expectedAccessGen: target.accessMutationGeneration,
                        relayOrigin: ready.relayOrigin.absoluteString,
                        deviceToken: ready.deviceToken,
                        expiresAtString: ready.expiresAt,
                        beforeSave: {
                            guard ContinuousClock.now < deadline else { throw CancellationError() }
                            _ = try RelayAccessValidation.decode(data, expectedInstanceID: pairing.instanceID, now: self.now())
                        }
                    )
                    cancelReactiveTokenRefresh()
                    transportAttemptID &+= 1
                    pendingDurableClear = nil
                    liveRelayEligible = true
                    setCachedPairingOutcome(.loaded(persisted))
                    await replaceLiveTransport(with: persisted, deadline: deadline, burstID: burstID)
                } catch {
                    splOwnerLog.error("relay access save failed: \(String(describing: error), privacy: .public)")
                }
            case .notConfigured:
                await performLiveDisable(deadline: deadline, burstID: burstID)
            }
        case .ready(let updatedPairing, let pairingGen, _, let newAccessGen):
            guard currentPairingGen == pairingGen, currentAccessGen == newAccessGen else {
                splOwnerLog.debug("handleRelayAccessOutcome .ready dropped: generation drift (store: \(currentPairingGen)/\(currentAccessGen), outcome: \(pairingGen)/\(newAccessGen))")
                return
            }
            liveRelayEligible = true
            setCachedPairingOutcome(.loaded(updatedPairing))
            await replaceLiveTransport(with: updatedPairing)

        case .notConfiguredLiveDisabled(let pairingGen, let accessGen):
            guard currentPairingGen == pairingGen, currentAccessGen == accessGen else {
                splOwnerLog.debug("handleRelayAccessOutcome .notConfiguredLiveDisabled dropped: generation drift")
                return
            }
            await performLiveDisable()

        case .durableClearPersisted(let clearedPairing, let pairingGen, _, let newAccessGen):
            guard currentPairingGen == pairingGen, currentAccessGen == newAccessGen else {
                splOwnerLog.debug("handleRelayAccessOutcome .durableClearPersisted dropped: generation drift")
                return
            }
            pendingDurableClear = nil
            setCachedPairingOutcome(.loaded(clearedPairing))
            relayAccessStatus = .unavailable

        case .durableClearFailed(let pairingGen, let accessGen):
            guard currentPairingGen == pairingGen, currentAccessGen == accessGen else {
                return
            }
            splOwnerLog.error("durable clear failed for pairingGen=\(pairingGen) accessGen=\(accessGen); live relay disabled")
            pendingDurableClear = (pairingGen: pairingGen, accessGen: accessGen)

        case .ignored:
            break
        }
    }

    private func performLiveDisable(deadline: ContinuousClock.Instant = .now + .seconds(15), burstID: UInt64? = nil) async {
        liveRelayEligible = false
        relayAccessStatus = .unavailable
        cancelReactiveTokenRefresh()
        transportAttemptID &+= 1
        let attempt = transportAttemptID
        let (pGen, aGen) = credentialStore.currentGenerations()

        // Retire the actual supervisor before any LAN dial or durable clear.
        // Its immutable pairing must no longer be available to autonomous reconnect.
        await disconnectCurrentTransport(deadline: deadline)
        guard operationIsCurrent(pairing: pGen, access: aGen, attempt: attempt) else { return }
        state = .disconnected
        health = .unknown
        guard ContinuousClock.now < deadline else {
            pendingDurableClear = (pairingGen: pGen, accessGen: aGen)
            return
        }
        do {
            let (cleared, _) = try credentialStore.clearRelayAccess(
                expectedPairingGen: pGen, expectedAccessGen: aGen
            )
            pendingDurableClear = nil
            setCachedPairingOutcome(.loaded(cleared))
        } catch {
            pendingDurableClear = (pairingGen: pGen, accessGen: aGen)
            splOwnerLog.error("durable clear failed; live relay remains disabled: \(String(describing: error), privacy: .public)")
        }
        guard let pairing = currentStoredPairing() else { return }
        await replaceLiveTransport(with: pairing, deadline: deadline, burstID: burstID)
    }

    private func operationIsCurrent(pairing: UInt64, access: UInt64, attempt: UInt64) -> Bool {
        running && !Task.isCancelled && transportAttemptID == attempt &&
            credentialStore.matches(pairing: pairing, access: access)
    }

    func replaceLiveTransport(
        with pairing: StoredPairing,
        deadline: ContinuousClock.Instant = .now + .seconds(15),
        burstID: UInt64? = nil
    ) async {
        guard running, !Task.isCancelled, ContinuousClock.now < deadline else { return }
        let candidates = usableCandidates(for: pairing)
        let hasLiveRoute = {
            if case .connected(let localPort, _) = state, establishedLoopbackPort == localPort, transport != nil {
                return true
            }
            return false
        }()
        guard !candidates.isEmpty else {
            if !hasLiveRoute { becomeDormant(tunnelManaged: false) }
            return
        }
        transportAttemptID &+= 1
        let attempt = transportAttemptID
        let (pGen, aGen) = credentialStore.currentGenerations()
        let candidate = makeTransport()
        let wait = CandidateConnectionWait()
        let connection: TunnelTransportConnection
        // A speculative replacement does not own the installed transport's
        // observer. Keep that observer alive if the candidate fails.
        let candidateAttemptObservation = Task { @MainActor [weak self] in
            for await attemptState in candidate.attemptStateUpdates {
                guard let self, self.running, !Task.isCancelled, self.transportAttemptID == attempt else {
                    return
                }
                self.supervisorAttemptState = attemptState
                self.updateConnectionVerdict()
            }
            guard let self, self.running, !Task.isCancelled, self.transportAttemptID == attempt, !self.isIntentionallyRetiring else { return }
            await self.handleUnexpectedAttemptStreamCompletion(forIncarnation: nil, forAttempt: attempt)
        }
        defer { candidateAttemptObservation.cancel() }
        do {
            connection = try await wait.connect(
                candidate,
                pairing: pairing,
                candidates: candidates,
                deadline: deadline,
                onLocalProxyStart: { [weak self] starting in
                    if starting {
                        self?.beginProxyStart(attempt: attempt)
                    } else {
                        self?.endProxyStart(attempt: attempt)
                    }
                }
            )
        } catch {
            candidateAttemptObservation.cancel()
            // Teardown can itself stall; it must not extend the dial deadline.
            Task { await candidate.disconnect() }
            splOwnerLog.error("replacement connect failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard operationIsCurrent(pairing: pGen, access: aGen, attempt: attempt),
              !rejectedAttemptIDs.contains(attempt),
              ContinuousClock.now < deadline else {
            candidateAttemptObservation.cancel()
            await candidate.disconnect()
            return
        }
        candidateAttemptObservation.cancel()
        install(candidate, connection: connection, attemptID: attempt, burstID: burstID)
    }

    private func install(
        _ candidate: any TunnelTransporting,
        connection: TunnelTransportConnection,
        attemptID: UInt64? = nil,
        burstID: UInt64? = nil,
        initialHealth: TunnelHealth = .healthy
    ) {
        if let attemptID {
            guard !rejectedAttemptIDs.contains(attemptID) else {
                splOwnerLog.notice("refusing install for rejected attempt \(attemptID)")
                Task { await candidate.disconnect() }
                return
            }
        }
        let oldTransport = transport
        transportIncarnation &+= 1
        transport = candidate
        establishedLoopbackPort = connection.localPort
        observe(candidate, generation: transportIncarnation, initialBurstID: burstID)
        if let oldTransport, oldTransport !== candidate { Task { await oldTransport.disconnect() } }
        publishingOptionalBurstID = burstID
        state = .connected(localPort: connection.localPort, via: connection.via)
        publishingOptionalBurstID = nil
        health = initialHealth
        probeWatchdog.noteConnectionEstablished()
        startProbe()
    }

    private func connectFromStoredPairing() async {
        guard running, !Task.isCancelled else {
            return
        }

        let pairing: StoredPairing
        switch loadPairingCached() {
        case .loaded(let loaded):
            pairing = loaded
        case .absent:
            becomeDormant(tunnelManaged: false)
            return
        case .failed:
            await failWithKeychainUnavailable()
            return
        }

        guard !usableCandidates(for: pairing).isEmpty else {
            becomeDormant(tunnelManaged: false)
            return
        }
        isTunnelManaged = true

        let (capturedPairingGen, capturedAccessGen) = credentialStore.currentGenerations()
        let refreshResult = await tokenRefresher.refreshIfNeeded(pairing, now())

        guard running, !Task.isCancelled,
              credentialStore.matches(pairing: capturedPairingGen, access: capturedAccessGen)
        else { return }

        switch refreshResult {
        case .refreshed(let updated):
            let (curPGen, curAGen) = credentialStore.currentGenerations()
            guard curPGen == capturedPairingGen && curAGen == capturedAccessGen else {
                splOwnerLog.info("proactive token refresh dropped: store generations drifted")
                await connect()
                return
            }

            guard case .enrolled(let deviceToken, let expiresAt) = updated.relayEnrollment else {
                await connect()
                return
            }

            do {
                let (persisted, _) = try credentialStore.updateRelayAccess(
                    expectedPairingGen: capturedPairingGen,
                    expectedAccessGen: capturedAccessGen,
                    relayOrigin: updated.relayEndpoint,
                    deviceToken: deviceToken,
                    expiresAtString: expiresAt
                )
                transportAttemptID &+= 1
                setCachedPairingOutcome(.loaded(persisted))
            } catch {
                splOwnerLog.info("proactive token refresh CAS save failed: \(String(describing: error), privacy: .public)")
            }
            await connect()

        case .notNeeded, .transientFailure:
            await connect()

        case .definitiveAuthFailure:
            if credentialStore.matches(pairing: capturedPairingGen, access: capturedAccessGen) {
                await retirePairingAndFailRevoked(expectedPairing: capturedPairingGen, expectedAccess: capturedAccessGen)
            }
        }
    }

    private func connect() async {
        establishmentInFlight = true
        defer {
            establishmentInFlight = false
            coalescedReconnectInFlight = false
        }

        var establishmentAttempt = 1
        while running, !Task.isCancelled {
            let outcome = await connectOnceForEstablishment()
            switch outcome {
            case .connected, .dormant, .terminal:
                return

            case .cancelled:
                if coalescedReconnectInFlight && running && !Task.isCancelled {
                    coalescedReconnectInFlight = false
                    continue
                }
                return

            case .retry:
                coalescedReconnectInFlight = false
                state = .connecting
                health = .unknown
                isBackingOff = true
                updateConnectionVerdict()
                let delay = Self.jitter(Self.establishmentBackoff(forAttempt: establishmentAttempt))
                establishmentAttempt += 1
                splOwnerLog.debug("tunnel establishment retry attempt=\(establishmentAttempt, privacy: .public)")
                let sleepTask: Task<Void, any Error> = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try await self.sleep(delay)
                }
                inFlightEstablishmentBackoffTask = sleepTask
                do {
                    try await sleepTask.value
                    inFlightEstablishmentBackoffTask = nil
                } catch {
                    inFlightEstablishmentBackoffTask = nil
                    isBackingOff = false
                    updateConnectionVerdict()
                    if coalescedReconnectInFlight && running && !Task.isCancelled {
                        coalescedReconnectInFlight = false
                        continue
                    }
                    return
                }
                isBackingOff = false
                updateConnectionVerdict()
            }
        }
    }

    private func connectOnceForEstablishment() async -> EstablishmentResult {
        guard running, !Task.isCancelled else {
            return .cancelled
        }

        let pairing: StoredPairing
        switch loadPairingCached() {
        case .loaded(let loaded):
            pairing = loaded
        case .absent:
            becomeDormant(tunnelManaged: false)
            return .dormant
        case .failed:
            await failWithKeychainUnavailable()
            return .terminal
        }

        let candidates = usableCandidates(for: pairing)
        guard !candidates.isEmpty else {
            becomeDormant(tunnelManaged: false)
            return .dormant
        }
        isTunnelManaged = true

        if transport == nil {
            state = .connecting
            health = .unknown
            stopProbe()
        }

        transportAttemptID &+= 1
        let attemptID = transportAttemptID
        let (pGen, aGen) = credentialStore.currentGenerations()
        let candidate = retainedCandidate ?? makeTransport()
        retainedCandidate = candidate
        attemptObservationTask?.cancel()
        attemptObservationTask = Task { @MainActor [weak self] in
            for await attemptState in candidate.attemptStateUpdates {
                guard let self, self.running, !Task.isCancelled, self.transportAttemptID == attemptID else {
                    return
                }
                self.supervisorAttemptState = attemptState
                self.updateConnectionVerdict()
            }
            guard let self, self.running, !Task.isCancelled, self.transportAttemptID == attemptID, !self.isIntentionallyRetiring else { return }
            await self.handleUnexpectedAttemptStreamCompletion(forIncarnation: nil, forAttempt: attemptID)
        }
        var loopbackAttempt = 0
        while operationIsCurrent(pairing: pGen, access: aGen, attempt: attemptID), !rejectedAttemptIDs.contains(attemptID) {
            do {
                let connectTask = Task<TunnelTransportConnection, any Error> { @MainActor in
                    try await candidate.connect(
                        pairing: pairing,
                        candidates: candidates,
                        onLocalProxyStart: { [weak self] starting in
                            if starting {
                                self?.beginProxyStart(attempt: attemptID)
                            } else {
                                self?.endProxyStart(attempt: attemptID)
                            }
                        }
                    )
                }
                inFlightConnectTask = connectTask
                let connection = try await connectTask.value
                inFlightConnectTask = nil
                guard operationIsCurrent(pairing: pGen, access: aGen, attempt: attemptID),
                      !rejectedAttemptIDs.contains(attemptID) else {
                    splOwnerLog.notice("ignoring late tunnel connect success for rejected/superseded attempt=\(attemptID)")
                    await candidate.disconnect()
                    return .cancelled
                }
                install(candidate, connection: connection, attemptID: attemptID, initialHealth: .unknown)
                return .connected
            } catch {
                inFlightConnectTask = nil
                guard operationIsCurrent(pairing: pGen, access: aGen, attempt: attemptID),
                      !rejectedAttemptIDs.contains(attemptID) else {
                    await candidate.disconnect()
                    return .cancelled
                }
                if error is CancellationError {
                    attemptObservationTask?.cancel()
                    attemptObservationTask = nil
                    await candidate.disconnect()
                    return .cancelled
                }
                if error is LoopbackProxyError, loopbackAttempt < Self.loopbackRetryDelays.count {
                    let delay = Self.loopbackRetryDelays[loopbackAttempt]
                    loopbackAttempt += 1
                    do { try await sleep(delay) } catch {
                        attemptObservationTask?.cancel()
                        attemptObservationTask = nil
                        await candidate.disconnect()
                        return .cancelled
                    }
                    continue
                }
                attemptObservationTask?.cancel()
                attemptObservationTask = nil
                await candidate.disconnect()
                guard operationIsCurrent(pairing: pGen, access: aGen, attempt: attemptID),
                      !rejectedAttemptIDs.contains(attemptID) else {
                    return .cancelled
                }
                if error is LoopbackProxyError {
                    retainedCandidate = nil
                    state = .error(.loopbackUnavailable)
                    health = .unknown
                    return .terminal
                }
                if let sessionError = error as? SessionError {
                    switch sessionError {
                    case .authRefreshRequired:
                        retainedCandidate = nil
                        beginReactiveTokenRefresh()
                        return .terminal
                    case .revoked:
                        retainedCandidate = nil
                        await retirePairingAndFailRevoked(expectedPairing: pGen, expectedAccess: aGen)
                        return .terminal
                    case .notEntitled:
                        retainedCandidate = nil
                        if case .connected(let localPort, _) = state, establishedLoopbackPort == localPort, transport != nil {
                            return .terminal
                        }
                        await failWithNotEntitled()
                        return .terminal
                    default: break
                    }
                }
                return .retry
            }
        }
        attemptObservationTask?.cancel()
        attemptObservationTask = nil
        await candidate.disconnect()
        return .cancelled
    }

    private func observe(_ transport: any TunnelTransporting, generation: UInt64, initialBurstID: UInt64? = nil) {
        let observedRevision = credentialStore.currentGenerations()
        stateObservationTask?.cancel()
        modeObservationTask?.cancel()
        attemptObservationTask?.cancel()

        stateObservationTask = Task { @MainActor [weak self] in
            var firstConnection = true
            for await tunnelState in transport.stateUpdates {
                guard let self, self.running, self.transportIncarnation == generation else {
                    return
                }
                if case .connected = tunnelState, firstConnection {
                    self.publishingOptionalBurstID = initialBurstID
                    firstConnection = false
                }
                await self.handle(tunnelState, pairingRevision: observedRevision.pairingGeneration)
                self.publishingOptionalBurstID = nil
            }
            guard let self, self.running, !Task.isCancelled, self.transportIncarnation == generation, !self.isIntentionallyRetiring else { return }
            await self.handleUnexpectedStateStreamCompletion(forIncarnation: generation)
        }

        modeObservationTask = Task { @MainActor [weak self] in
            for await mode in transport.connectionModeUpdates {
                guard let self, self.running, !Task.isCancelled, self.transportIncarnation == generation else {
                    return
                }
                self.handleConnectionMode(mode)
            }
        }

        attemptObservationTask = Task { @MainActor [weak self] in
            var firstAttempt = true
            for await attempt in transport.attemptStateUpdates {
                guard let self, self.running, !Task.isCancelled, self.transportIncarnation == generation else {
                    return
                }
                let oldAttempt = self.supervisorAttemptState
                self.supervisorAttemptState = attempt
                self.updateConnectionVerdict()
                if !firstAttempt, oldAttempt != .connected, attempt == .connected, case .connected(let port, _) = self.state {
                    let incarnation = self.transportIncarnation
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.running, self.transportIncarnation == incarnation, self.localPort == port,
                              let pairing = self.currentStoredPairing() else { return }
                        self.optionalBurstID &+= 1
                        let burst = self.optionalBurstID
                        let (pGen, aGen) = self.credentialStore.currentGenerations()
                        if let identity = journalVersionMetadataIdentity(for: pairing) {
                            await self.clientSelfSequencer.enqueue(
                                target: .init(localPort: port, identity: identity, pairingGeneration: pGen,
                                              metadataGeneration: self.journalVersion.currentGeneration()),
                                burstID: burst
                            )
                        }
                        await self.relayAccessSequencer.enqueue(
                            target: .init(localPort: port, instanceID: pairing.instanceID,
                                          pairingGeneration: pGen, accessMutationGeneration: aGen, transportAttempt: self.transportAttemptID),
                            burstID: burst
                        )
                    }
                }
                firstAttempt = false
            }
            guard let self, self.running, !Task.isCancelled, self.transportIncarnation == generation, !self.isIntentionallyRetiring else { return }
            await self.handleUnexpectedAttemptStreamCompletion(forIncarnation: generation, forAttempt: nil)
        }
    }

    func handleUnexpectedStateStreamCompletion(forIncarnation incarnation: UInt64?) async {
        guard running, !Task.isCancelled, !isIntentionallyRetiring else { return }
        if let incarnation, transportIncarnation != incarnation { return }

        splOwnerLog.notice("unexpected tunnel state stream completion observed (incarnation=\(incarnation ?? 0), attempt=\(self.transportAttemptID))")
        await failClosedAfterUnexpectedStreamCompletion(forAttempt: transportAttemptID)
    }

    func handleUnexpectedAttemptStreamCompletion(
        forIncarnation incarnation: UInt64?,
        forAttempt attempt: UInt64?
    ) async {
        guard running, !Task.isCancelled, !isIntentionallyRetiring else { return }
        if let incarnation, transportIncarnation != incarnation { return }
        if let attempt, transportAttemptID != attempt { return }

        splOwnerLog.notice("unexpected tunnel attempt stream completion observed (incarnation=\(incarnation ?? 0), attempt=\(attempt ?? self.transportAttemptID))")
        await failClosedAfterUnexpectedStreamCompletion(forAttempt: attempt ?? transportAttemptID)
    }

    private func failClosedAfterUnexpectedStreamCompletion(forAttempt attempt: UInt64) async {
        rejectedAttemptIDs.insert(attempt)
        transportAttemptID &+= 1
        await disconnectCurrentTransport()
        guard running else { return }
        state = .disconnected
        health = .unknown
        updateConnectionVerdict()
    }

    private func installWakeUnlockObservers() {
        if didWakeObserver == nil {
            didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleWakeOrUnlock()
                }
            }
        }

        if screenUnlockedObserver == nil {
            screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleWakeOrUnlock()
                }
            }
        }
    }

    private func removeWakeUnlockObservers() {
        if let observer = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            didWakeObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
    }

    private func handle(_ tunnelState: TunnelState, pairingRevision: UInt64) async {
        guard running else {
            return
        }
        if case .error = state {
            return
        }

        switch tunnelState {
        case .disconnected:
            stopProbe()
            state = .disconnected
            health = .unknown

        case .connecting, .tlsHandshaking, .awaitingBroker:
            stopProbe()
            state = .connecting
            health = .unknown

        case .connected(let via):
            if let port = establishedLoopbackPort {
                let wasConnected = {
                    if case .connected = state {
                        return true
                    }
                    return false
                }()
                state = .connected(localPort: port, via: Self.route(for: via))
                if !wasConnected {
                    probeWatchdog.noteConnectionEstablished()
                    startProbe()
                }
            } else if !establishmentInFlight {
                splOwnerLog.error("tunnel republished connected with no remembered loopback port")
            }

        case .failed(let error):
            // This is still the installed transport (observe fences incarnation).
            // Updating relay credentials does not invalidate its failure events;
            // a failed replacement can leave it installed with older credentials.
            let currentRevision = credentialStore.currentGenerations()
            guard currentRevision.pairingGeneration == pairingRevision else { return }
            splOwnerLog.notice("tunnel failed error=\(String(describing: error), privacy: .public)")
            switch error {
            case .authRefreshRequired:
                beginReactiveTokenRefresh()
            case .revoked:
                await retirePairingAndFailRevoked(expectedPairing: pairingRevision, expectedAccess: currentRevision.accessMutationGeneration)
            case .notEntitled:
                await failWithNotEntitled()
            default:
                stopProbe()
                state = .connecting
                health = .unknown
            }
        }
    }

    private func handleConnectionMode(_ mode: ConnectionMode?) {
        guard case .connected(let localPort, _) = state else {
            return
        }
        let route: TunnelConnectionRoute = (mode == .plDirect) ? .lan : .relay
        state = .connected(localPort: localPort, via: route)
    }

    private func beginReactiveTokenRefresh() {
        guard authRefreshTask == nil else {
            pendingReactiveRefresh = true
            return
        }
        let hasLiveRoute = {
            if case .connected(let localPort, _) = state, establishedLoopbackPort == localPort, transport != nil {
                return true
            }
            return false
        }()
        if !hasLiveRoute {
            state = .connecting
            health = .unknown
        }
        authRefreshGeneration += 1
        let generation = authRefreshGeneration
        authRefreshTask = Task { @MainActor [weak self] in
            await self?.runReactiveTokenRefresh(generation: generation)
        }
    }

    private func finishReactiveTokenRefresh(generation: Int) {
        guard authRefreshGeneration == generation else {
            return
        }
        authRefreshTask = nil
    }

    private func cancelReactiveTokenRefresh() {
        authRefreshTask?.cancel()
        authRefreshTask = nil
        authRefreshGeneration += 1
        pendingReactiveRefresh = false
    }

    private func runReactiveTokenRefresh(generation: Int) async {
        defer {
            finishReactiveTokenRefresh(generation: generation)
        }

        var attempt = 1
        while running, !Task.isCancelled {
            guard authRefreshGeneration == generation else { return }
            let pairing: StoredPairing
            switch loadPairingCached() {
            case .loaded(let loaded):
                pairing = loaded
            case .absent:
                await disconnectCurrentTransport()
                guard running, !Task.isCancelled else {
                    return
                }
                becomeDormant(tunnelManaged: false)
                return
            case .failed:
                await failWithKeychainUnavailable()
                return
            }

            let (capturedPairingGen, capturedAccessGen) = credentialStore.currentGenerations()
            let result = await tokenRefresher.refreshNow(pairing)
            guard running, !Task.isCancelled, authRefreshGeneration == generation,
                  credentialStore.matches(pairing: capturedPairingGen, access: capturedAccessGen)
            else { return }

            switch result {
            case .refreshed(let updated):
                let (curPGen, curAGen) = credentialStore.currentGenerations()
                guard curPGen == capturedPairingGen && curAGen == capturedAccessGen else {
                    splOwnerLog.info("reactive token refresh dropped: generations drifted")
                    return
                }

                guard case .enrolled(let deviceToken, let expiresAt) = updated.relayEnrollment else {
                    return
                }

                do {
                    let (persisted, _) = try credentialStore.updateRelayAccess(
                        expectedPairingGen: capturedPairingGen,
                        expectedAccessGen: capturedAccessGen,
                        relayOrigin: updated.relayEndpoint,
                        deviceToken: deviceToken,
                        expiresAtString: expiresAt
                    )
                    transportAttemptID &+= 1
                    setCachedPairingOutcome(.loaded(persisted))
                } catch {
                    splOwnerLog.info("reactive token refresh CAS failed: \(String(describing: error), privacy: .public)")
                    return
                }

                let accepted = credentialStore.currentGenerations()
                let acceptedAttempt = transportAttemptID
                await disconnectCurrentTransport()
                guard operationIsCurrent(pairing: accepted.pairingGeneration, access: accepted.accessMutationGeneration, attempt: acceptedAttempt),
                      authRefreshGeneration == generation else { return }
                pendingReactiveRefresh = false
                await connect()
                guard running, !Task.isCancelled, authRefreshGeneration == generation else {
                    return
                }
                if pendingReactiveRefresh {
                    pendingReactiveRefresh = false
                    state = .connecting
                    health = .unknown
                    let delay = Self.jitter(Self.establishmentBackoff(forAttempt: attempt))
                    attempt += 1
                    do {
                        try await sleep(delay)
                    } catch {
                        return
                    }
                    continue
                }
                return

            case .transientFailure:
                splOwnerLog.info("reactive token refresh transient failure; preserving pairing")
                let hasLiveRoute = {
                    if case .connected(let localPort, _) = state, establishedLoopbackPort == localPort, transport != nil {
                        return true
                    }
                    return false
                }()
                if !hasLiveRoute {
                    state = .connecting
                    health = .unknown
                }
                let delay = Self.jitter(Self.establishmentBackoff(forAttempt: attempt))
                attempt += 1
                do {
                    try await sleep(delay)
                } catch {
                    return
                }

            case .notNeeded:
                let lanCandidates = pairing.localEndpoints.filter {
                    !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && 1...65535 ~= $0.port
                }
                if !lanCandidates.isEmpty {
                    splOwnerLog.info("reactive token refresh not needed; preserving LAN pairing")
                    await disconnectCurrentTransport()
                    guard running, !Task.isCancelled, authRefreshGeneration == generation,
                          credentialStore.matches(pairing: capturedPairingGen, access: capturedAccessGen) else { return }
                    await connect()
                    return
                } else {
                    if credentialStore.matches(pairing: capturedPairingGen, access: capturedAccessGen) {
                        await retirePairingAndFailRevoked(expectedPairing: capturedPairingGen, expectedAccess: capturedAccessGen)
                    }
                    return
                }

            case .definitiveAuthFailure:
                if credentialStore.matches(pairing: capturedPairingGen, access: capturedAccessGen) {
                    await retirePairingAndFailRevoked(expectedPairing: capturedPairingGen, expectedAccess: capturedAccessGen)
                }
                return
            }
        }
    }

    private func startPathMonitor() {
        pathMonitor.start { [weak self] status in
            Task { @MainActor in
                self?.handlePathStatus(status)
            }
        }
    }

    private func handlePathStatus(_ status: NetworkPathStatus) {
        let previous = currentPathSignature
        currentPathSignature = status.signature
        guard case .connected = state,
              status.isSatisfied,
              let previous,
              previous.bucket != status.bucket
        else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.transport?.requestReconnect()
        }
    }

    private func startProbe() {
        guard probeTask == nil else {
            return
        }
        probeTask = Task { @MainActor [weak self] in
            var interval = Self.probeWatchdogPolicy.healthyInterval
            while let self, !Task.isCancelled {
                do {
                    try await self.sleep(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.running,
                      case .connected = self.state,
                      let localPort = self.establishedLoopbackPort
                else {
                    return
                }
                interval = await self.runProbe(localPort: localPort)
            }
        }
    }

    private func stopProbe() {
        probeTask?.cancel()
        probeTask = nil
    }

    private func runProbe(localPort: Int) async -> Duration {
        guard let transport else {
            return Self.probeWatchdogPolicy.healthyInterval
        }
        let before = await transport.inboundActivitySnapshot()
        let succeeded = await probe(localPort, Self.probeTimeout)
        let inboundMoving: Bool
        if succeeded {
            inboundMoving = false
        } else {
            let after = await transport.inboundActivitySnapshot()
            inboundMoving = after != before
        }

        let verdict = probeWatchdog.evaluate(
            probeSucceeded: succeeded,
            inboundAdvanced: inboundMoving,
            activeLocalTransfers: 0
        )
        applyProbeHealth(verdict.health)
        if verdict.action == .reconnect {
            let failureLimit = inboundMoving
                ? Self.probeWatchdogPolicy.activeInboundFailureLimit
                : Self.probeWatchdogPolicy.silentFailureLimit
            splOwnerLog.notice("watchdog probe failed limit=\(failureLimit, privacy: .public) inbound_moving=\(inboundMoving, privacy: .public) reconnect=true")
            await transport.requestReconnect()
        }
        return verdict.nextInterval
    }

    private func applyProbeHealth(_ probeHealth: ProbeHealth) {
        switch probeHealth {
        case .healthy:
            health = .healthy
        case .degraded:
            health = .degraded
        case .unknown:
            break
        }
    }

    private func usableCandidates(for pairing: StoredPairing) -> [TransportEndpoint] {
        TransportEndpoint.candidates(for: pairing).filter { candidate in
            switch candidate {
            case .lan(let host, let port, _, _):
                return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && 1...65535 ~= port
            case .relay(let endpoint, let instanceID, let deviceToken):
                guard liveRelayEligible else { return false }
                return endpoint.scheme != nil &&
                    !instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    private func loadPairingCached() -> PairingLoadOutcome {
        if let cachedPairingOutcome {
            return cachedPairingOutcome
        }
        let outcome: PairingLoadOutcome
        do {
            if let loaded = try loadPairing() {
                outcome = .loaded(loaded)
            } else {
                outcome = .absent
            }
        } catch {
            splOwnerLog.debug("pairing load unavailable: \(String(describing: type(of: error)), privacy: .public)")
            outcome = .failed
        }
        setCachedPairingOutcome(outcome)
        return outcome
    }

    private func setCachedPairingOutcome(_ outcome: PairingLoadOutcome) {
        cachedPairingOutcome = outcome
        switch outcome {
        case .loaded(let pairing):
            journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))
        case .absent:
            journalVersion.clear()
        case .failed:
            journalVersion.disconnected()
        }
        relayAccessStatus = relayAccessStatus(for: outcome, preserving: relayAccessStatus)
        refreshPairingDerivedState(from: outcome)
    }

    private func relayAccessStatus(
        for outcome: PairingLoadOutcome,
        preserving current: PairingRelayAccessStatus
    ) -> PairingRelayAccessStatus {
        switch outcome {
        case .loaded(let pairing):
            return relayAccessStatus(for: pairing)
        case .absent:
            return .noPairing
        case .failed:
            return current
        }
    }

    private func relayAccessStatus(for pairing: StoredPairing) -> PairingRelayAccessStatus {
        guard liveRelayEligible else { return .unavailable }
        switch pairing.relayEnrollment {
        case .enrolled:
            return .available
        case .unavailable:
            return .unavailable
        }
    }

    private static func isHomePairing(_ pairing: StoredPairing) -> Bool {
        pairing.localEndpoints.contains { endpoint in
            LoopbackHost.isLoopbackHost(endpoint.host)
        }
    }

    private func invalidatePairingCache() {
        cachedPairingOutcome = nil
    }

    private func refreshTunnelManagedFromStoredPairing() {
        refreshPairingDerivedState(from: loadPairingCached())
    }

    private func refreshPairingDerivedState(from outcome: PairingLoadOutcome) {
        switch outcome {
        case .loaded(let pairing):
            hasPersistedPairing = true
            isTunnelManaged = !usableCandidates(for: pairing).isEmpty
            isPairedHome = Self.isHomePairing(pairing)
        case .absent:
            hasPersistedPairing = false
            isTunnelManaged = false
            isPairedHome = false
        case .failed:
            hasPersistedPairing = true
            isTunnelManaged = false
            isPairedHome = false
        }
        updateConnectionVerdict()
    }

    private func becomeDormant(tunnelManaged: Bool) {
        isTunnelManaged = tunnelManaged
        inFlightConnectTask?.cancel()
        inFlightConnectTask = nil
        retainedCandidate = nil
        state = .disconnected
        health = .unknown
        updateConnectionVerdict()
    }

    private func retirePairingAndFailRevoked(expectedPairing: UInt64? = nil, expectedAccess: UInt64? = nil) async {
        var removed = false
        do {
            if let expectedPairing, let expectedAccess {
                try credentialStore.delete(expectedGeneration: expectedPairing, expectedAccessGeneration: expectedAccess)
            } else {
                try deletePairing()
            }
            removed = true
        } catch PairingCredentialStoreError.staleGeneration {
            return
        } catch {
            splOwnerLog.error("pairing delete failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        let revision = credentialStore.currentGenerations()
        transportAttemptID &+= 1
        let attempt = transportAttemptID
        if removed {
            setCachedPairingOutcome(.absent)
        } else {
            liveRelayEligible = false
            relayAccessStatus = .unavailable
        }
        await disconnectCurrentTransport()
        guard running, transportAttemptID == attempt,
              credentialStore.matches(pairing: revision.pairingGeneration, access: revision.accessMutationGeneration) else { return }
        state = .error(.revoked)
        health = .unknown
    }

    private func failWithKeychainUnavailable() async {
        let attempt = transportAttemptID
        await disconnectCurrentTransport()
        guard running, transportAttemptID == attempt else { return }
        state = .error(.keychainUnavailable)
        health = .unknown
    }

    private func failWithNotEntitled() async {
        let attempt = transportAttemptID
        await disconnectCurrentTransport()
        guard running, transportAttemptID == attempt else { return }
        state = .error(.notEntitled)
        health = .unknown
    }

    private func disconnectCurrentTransport(deadline: ContinuousClock.Instant? = nil) async {
        isIntentionallyRetiring = true
        defer { isIntentionallyRetiring = false }
        journalVersion.disconnected()
        stopProbe()
        establishedLoopbackPort = nil
        inFlightConnectTask?.cancel()
        inFlightConnectTask = nil
        let retainedCandidate = self.retainedCandidate
        self.retainedCandidate = nil
        stateObservationTask?.cancel()
        stateObservationTask = nil
        modeObservationTask?.cancel()
        modeObservationTask = nil
        attemptObservationTask?.cancel()
        attemptObservationTask = nil
        supervisorAttemptState = .idle
        let transport = self.transport
        self.transport = nil
        if let deadline {
            let completion = AsyncStream<Void>.makeStream()
            Task { @MainActor in
                await transport?.disconnect()
                if let retainedCandidate {
                    if let transport {
                        if retainedCandidate !== transport {
                            await retainedCandidate.disconnect()
                        }
                    } else {
                        await retainedCandidate.disconnect()
                    }
                }
                completion.continuation.finish()
            }
            let timer = Task {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                completion.continuation.finish()
            }
            for await _ in completion.stream {}
            timer.cancel()
        } else {
            await transport?.disconnect()
            if let retainedCandidate {
                if let transport {
                    if retainedCandidate !== transport {
                        await retainedCandidate.disconnect()
                    }
                } else {
                    await retainedCandidate.disconnect()
                }
            }
        }
        updateConnectionVerdict()
    }

    func updateConnectionVerdict() {
        connectionVerdict = reduceConnectionVerdict()
    }

    func reduceConnectionVerdict() -> JournalConnectionVerdict {
        Self.reduceConnectionVerdict(
            state: state,
            hasPersistedPairing: hasPersistedPairing,
            isTunnelManaged: isTunnelManaged,
            isPairedHome: isPairedHome,
            supervisorAttemptState: supervisorAttemptState,
            isProxyStarting: isProxyStarting,
            establishedLoopbackPort: establishedLoopbackPort,
            hasTransport: transport != nil
        )
    }

    static func reduceConnectionVerdict(
        state: TunnelLifecycleState,
        hasPersistedPairing: Bool,
        isTunnelManaged: Bool,
        isPairedHome: Bool = false,
        supervisorAttemptState: TunnelSupervisorAttemptState,
        isProxyStarting: Bool,
        establishedLoopbackPort: Int?,
        hasTransport: Bool
    ) -> JournalConnectionVerdict {
        // Layer (a): Live Installed Route
        if case .connected(let localPort, _) = state,
           establishedLoopbackPort == localPort,
           hasTransport {
            let msg = isPairedHome ? "connected to your journal on this Mac" : "sync can connect through your journal"
            return JournalConnectionVerdict(
                severity: .good,
                message: msg,
                caption: nil,
                axToken: PairingConnectionAXState.connected.axToken,
                failureCause: nil
            )
        }

        // Layer (b): Active Attempt In Flight
        let isAttempting: Bool = isProxyStarting || supervisorAttemptState == .attempting

        if isAttempting {
            return JournalConnectionVerdict(
                severity: .warn,
                message: "connecting to your journal…",
                caption: nil,
                axToken: PairingConnectionAXState.connecting.axToken,
                failureCause: nil
            )
        }

        // Layer (c): Failure / Backoff / Redrive Sleep / No Route / Owner Action Error
        guard hasPersistedPairing else {
            return .neutral
        }

        if case .error(let error) = state {
            switch error {
            case .notEntitled:
                return JournalConnectionVerdict(
                    severity: .attention,
                    message: "can't sync over the internet yet",
                    caption: UICopy.PAIRING_NOTENTITLED_RECOVERY,
                    axToken: PairingConnectionAXState.notEntitled.axToken,
                    failureCause: .notEntitled
                )
            case .revoked:
                return JournalConnectionVerdict(
                    severity: .attention,
                    message: "pairing was revoked. pair again to reconnect.",
                    caption: nil,
                    axToken: PairingConnectionAXState.revoked.axToken,
                    failureCause: .revoked
                )
            case .loopbackUnavailable:
                return JournalConnectionVerdict(
                    severity: .attention,
                    message: "paired, but the local connection couldn't start",
                    caption: nil,
                    axToken: PairingConnectionAXState.loopbackUnavailable.axToken,
                    failureCause: .loopbackUnavailable
                )
            case .keychainUnavailable:
                return JournalConnectionVerdict(
                    severity: .attention,
                    message: "paired, but this Mac couldn't read the pairing",
                    caption: nil,
                    axToken: PairingConnectionAXState.keychainUnavailable.axToken,
                    failureCause: .keychainUnavailable
                )
            }
        }

        if !isTunnelManaged {
            return JournalConnectionVerdict(
                severity: .attention,
                message: "can't reach your journal right now",
                caption: "waiting for a direct network route or relay connection",
                axToken: PairingConnectionAXState.noRoute.axToken,
                failureCause: .noRoute
            )
        }

        return JournalConnectionVerdict(
            severity: .attention,
            message: "can't reach your journal right now",
            caption: nil,
            axToken: PairingConnectionAXState.unreachable.axToken,
            failureCause: .unreachable(nil)
        )
    }

    private static func route(for via: ConnectedVia) -> TunnelConnectionRoute {
        switch via {
        case .lanDirect:
            return .lan
        case .relay:
            return .relay
        }
    }

    private static func establishmentBackoff(forAttempt attempt: Int) -> Duration {
        establishmentRetryDelays[min(max(attempt - 1, 0), establishmentRetryDelays.count - 1)]
    }

    private static func jitter(_ duration: Duration) -> Duration {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return .milliseconds(Int(seconds * 1_000 * Double.random(in: 0.75...1.25)))
    }

    static func httpStatusProbe(localPort: Int, timeout: Duration) async -> Bool {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/app/network/api/status") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout.timeInterval

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return 200..<300 ~= http.statusCode
        } catch {
            return false
        }
    }
}

private enum EstablishmentResult {
    case connected
    case dormant
    case retry
    case terminal
    case cancelled
}

private enum PairingLoadOutcome {
    case loaded(StoredPairing)
    case absent
    case failed
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

// A cancelled network operation may finish after its caller's deadline. The
// continuation has one winner; the late candidate is always disconnected.
@MainActor
private final class CandidateConnectionWait {
    private var continuation: CheckedContinuation<TunnelTransportConnection, any Error>?
    private var completed = false
    private var timer: Task<Void, Never>?
    private var operation: Task<Void, Never>?

    func connect(
        _ candidate: any TunnelTransporting,
        pairing: StoredPairing,
        candidates: [TransportEndpoint],
        deadline: ContinuousClock.Instant,
        onLocalProxyStart: (@MainActor (Bool) -> Void)? = nil
    ) async throws -> TunnelTransportConnection {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if completed {
                    self.continuation = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                operation = Task { @MainActor in
                    do {
                        let connection = try await candidate.connect(
                            pairing: pairing,
                            candidates: candidates,
                            onLocalProxyStart: onLocalProxyStart
                        )
                        guard !self.completed, ContinuousClock.now < deadline else {
                            await candidate.disconnect()
                            self.finish(.failure(BoundedLoopbackClientError.timedOut))
                            return
                        }
                        self.finish(.success(connection))
                    } catch {
                        self.finish(.failure(error))
                    }
                }
                timer = Task { @MainActor in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    self.finish(.failure(BoundedLoopbackClientError.timedOut))
                    self.operation?.cancel()
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(.failure(CancellationError()))
                self.operation?.cancel()
            }
        }
    }

    private func finish(_ result: Result<TunnelTransportConnection, any Error>) {
        guard !completed else { return }
        completed = true
        timer?.cancel()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
