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

private final class RelayOutcomeTarget: @unchecked Sendable {
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
    private(set) var health: TunnelHealth = .unknown
    private(set) var isTunnelManaged = false
    private(set) var isPairedHome = false
    private(set) var relayAccessStatus: PairingRelayAccessStatus = .noPairing
    private(set) var liveRelayEligible: Bool = true
    private(set) var pendingDurableClear: (pairingGen: UInt64, accessGen: UInt64)?
    private(set) var transportGeneration: UInt64 = 0

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
    private var running = false
    @ObservationIgnored
    private var cachedPairingOutcome: PairingLoadOutcome?
    @ObservationIgnored
    private var probeWatchdog = ProbeWatchdog(policy: TunnelLifecycleOwner.probeWatchdogPolicy)
    @ObservationIgnored
    private var suppressOptionalJobsOnNextConnected = false

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
        relayAccessSequencer: JournalRelayAccessSequencer? = nil
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

        let jv = self.journalVersion
        self.clientSelfSequencer = clientSelfSequencer ?? JournalClientSelfSequencer(
            onJournalMetadataUpdated: { identity, gen, version, name in
                Task { @MainActor in
                    jv.applyDirectly(identity: identity, generation: gen, version: version, name: name, markCurrent: true)
                }
            }
        )

        let target = RelayOutcomeTarget()
        self.relayOutcomeTarget = target
        if let relayAccessSequencer {
            self.relayAccessSequencer = relayAccessSequencer
        } else {
            self.relayAccessSequencer = JournalRelayAccessSequencer(
                credentialStore: store,
                onOutcome: { [weak target] outcome in
                    Task { @MainActor in
                        await target?.owner?.handleRelayAccessOutcome(outcome)
                    }
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
        removeWakeUnlockObservers()
        startTask?.cancel()
        startTask = nil
        cancelReactiveTokenRefresh()
        pathMonitor.stop()
        currentPathSignature = nil
        Task { [clientSelfSequencer, relayAccessSequencer] in
            await clientSelfSequencer.cancel()
            await relayAccessSequencer.cancel()
        }
        await disconnectCurrentTransport()
        state = .disconnected
        health = .unknown
    }

    func reevaluatePairing() async {
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
        Task { [clientSelfSequencer, relayAccessSequencer] in
            await clientSelfSequencer.cancel()
            await relayAccessSequencer.cancel()
        }
        startTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.running, !Task.isCancelled else {
                return
            }
            await self.disconnectCurrentTransport()
            await self.connectFromStoredPairing()
        }
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
        if case .connected(let port, _) = new {
            journalVersion.adoptConnectedPort(port)

            if case .connected(let oldPort, _) = old, oldPort == port {
                return
            }

            if suppressOptionalJobsOnNextConnected {
                suppressOptionalJobsOnNextConnected = false
                return
            }

            if let pending = pendingDurableClear {
                let (pGen, aGen) = credentialStore.currentGenerations()
                if pending.pairingGen == pGen && pending.accessGen == aGen {
                    if (try? credentialStore.clearRelayAccess(expectedPairingGen: pGen, expectedAccessGen: aGen)) != nil {
                        pendingDurableClear = nil
                        if let current = currentStoredPairing() {
                            setCachedPairingOutcome(.loaded(current))
                        }
                    }
                } else {
                    pendingDurableClear = nil
                }
            }

            if let pairing = currentStoredPairing(), let identity = journalVersionMetadataIdentity(for: pairing) {
                let (pGen, aGen) = credentialStore.currentGenerations()
                let metaGen = journalVersion.currentGeneration()
                Task { [clientSelfSequencer] in
                    await clientSelfSequencer.enqueue(
                        target: JournalClientSelfSequencer.TargetConnection(
                            localPort: port,
                            identity: identity,
                            pairingGeneration: pGen,
                            metadataGeneration: metaGen
                        )
                    )
                }
                Task { [relayAccessSequencer] in
                    await relayAccessSequencer.enqueue(
                        target: JournalRelayAccessSequencer.TargetConnection(
                            localPort: port,
                            instanceID: pairing.instanceID,
                            pairingGeneration: pGen,
                            accessMutationGeneration: aGen
                        )
                    )
                }
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
        switch outcome {
        case .ready(let updatedPairing):
            liveRelayEligible = true
            setCachedPairingOutcome(.loaded(updatedPairing))
            await replaceLiveTransport(with: updatedPairing)

        case .notConfiguredLiveDisabled:
            liveRelayEligible = false
            if case .loaded(let current) = cachedPairingOutcome {
                relayAccessStatus = relayAccessStatus(for: current)
            } else {
                relayAccessStatus = .unavailable
            }

        case .durableClearPersisted:
            pendingDurableClear = nil
            if let current = currentStoredPairing() {
                setCachedPairingOutcome(.loaded(current))
            }

        case .durableClearFailed(let pairingGen, let accessGen):
            pendingDurableClear = (pairingGen: pairingGen, accessGen: accessGen)

        case .ignored:
            break
        }
    }

    func replaceLiveTransport(with pairing: StoredPairing) async {
        guard running, !Task.isCancelled else { return }
        transportGeneration &+= 1
        let generation = transportGeneration
        let candidates = usableCandidates(for: pairing)
        guard !candidates.isEmpty else {
            becomeDormant(tunnelManaged: false)
            return
        }

        let newTransport = makeTransport()
        let connection: TunnelTransportConnection
        do {
            connection = try await newTransport.connect(pairing: pairing, candidates: candidates)
        } catch {
            splOwnerLog.error("replaceLiveTransport connect failed: \(String(describing: error), privacy: .public)")
            return
        }

        guard running, !Task.isCancelled, transportGeneration == generation else {
            await newTransport.disconnect()
            return
        }

        let oldTransport = self.transport
        self.transport = newTransport
        self.establishedLoopbackPort = connection.localPort

        observe(newTransport, generation: generation)

        Task {
            await oldTransport?.disconnect()
        }

        let route: TunnelConnectionRoute = connection.via == .lan ? .lan : .relay
        suppressOptionalJobsOnNextConnected = true
        state = .connected(localPort: connection.localPort, via: route)
        health = .healthy

        journalVersion.adoptConnectedPort(connection.localPort)
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

        switch await tokenRefresher.refreshIfNeeded(pairing, now()) {
        case .refreshed(let updated):
            do {
                try savePairing(updated)
            } catch {
                splOwnerLog.error("device token refresh save failed: \(String(describing: type(of: error)), privacy: .public)")
                await failWithKeychainUnavailable()
                return
            }
            setCachedPairingOutcome(.loaded(updated))
            await connect()

        case .notNeeded, .transientFailure:
            await connect()

        case .definitiveAuthFailure:
            await retirePairingAndFailRevoked()
        }
    }

    private func connect() async {
        establishmentInFlight = true
        defer {
            establishmentInFlight = false
        }

        var establishmentAttempt = 1
        while running, !Task.isCancelled {
            switch await connectOnceForEstablishment() {
            case .connected, .dormant, .terminal, .cancelled:
                return

            case .retry:
                state = .connecting
                health = .unknown
                let delay = Self.jitter(Self.establishmentBackoff(forAttempt: establishmentAttempt))
                establishmentAttempt += 1
                splOwnerLog.debug("tunnel establishment retry attempt=\(establishmentAttempt, privacy: .public)")
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
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

        state = .connecting
        health = .unknown
        stopProbe()

        let transport = ensureTransport()
        var loopbackAttempt = 0
        while running, !Task.isCancelled {
            do {
                let connection = try await transport.connect(pairing: pairing, candidates: candidates)
                guard running, !Task.isCancelled else {
                    return .cancelled
                }
                establishedLoopbackPort = connection.localPort
                let route: TunnelConnectionRoute = connection.via == .lan ? .lan : .relay
                state = .connected(localPort: connection.localPort, via: route)
                health = .unknown
                probeWatchdog.noteConnectionEstablished()
                startProbe()
                splOwnerLog.notice("tunnel connected route=\(String(describing: connection.via), privacy: .public) local_port=\(connection.localPort, privacy: .public)")
                return .connected
            } catch is CancellationError {
                return .cancelled
            } catch let error as LoopbackProxyError {
                guard loopbackAttempt < Self.loopbackRetryDelays.count else {
                    splOwnerLog.error("loopback unavailable after retries: \(String(describing: error), privacy: .public)")
                    await disconnectCurrentTransport()
                    state = .error(.loopbackUnavailable)
                    health = .unknown
                    return .terminal
                }
                let delay = Self.loopbackRetryDelays[loopbackAttempt]
                loopbackAttempt += 1
                splOwnerLog.info("loopback start retry attempt=\(loopbackAttempt + 1, privacy: .public)")
                do {
                    try await sleep(delay)
                } catch {
                    return .cancelled
                }
            } catch SessionError.authRefreshRequired {
                beginReactiveTokenRefresh()
                return .terminal
            } catch SessionError.revoked {
                await retirePairingAndFailRevoked()
                return .terminal
            } catch SessionError.notEntitled {
                await failWithNotEntitled()
                return .terminal
            } catch {
                splOwnerLog.debug("tunnel connect nonterminal failure: \(String(describing: type(of: error)), privacy: .public)")
                return .retry
            }
        }
        return .cancelled
    }

    private func ensureTransport() -> any TunnelTransporting {
        if let transport {
            return transport
        }
        transportGeneration &+= 1
        let generation = transportGeneration
        let transport = makeTransport()
        self.transport = transport
        observe(transport, generation: generation)
        return transport
    }

    private func observe(_ transport: any TunnelTransporting, generation: UInt64) {
        stateObservationTask?.cancel()
        modeObservationTask?.cancel()

        stateObservationTask = Task { @MainActor [weak self] in
            for await tunnelState in transport.stateUpdates {
                guard let self, self.running, self.transportGeneration == generation else {
                    return
                }
                await self.handle(tunnelState)
            }
        }

        modeObservationTask = Task { @MainActor [weak self] in
            for await mode in transport.connectionModeUpdates {
                guard let self, self.running, self.transportGeneration == generation else {
                    return
                }
                self.handleConnectionMode(mode)
            }
        }
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

    private func handle(_ tunnelState: TunnelState) async {
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
                }
                startProbe()
            } else if !establishmentInFlight {
                splOwnerLog.error("tunnel republished connected with no remembered loopback port")
            }

        case .failed(let error):
            splOwnerLog.notice("tunnel failed error=\(String(describing: error), privacy: .public)")
            switch error {
            case .authRefreshRequired:
                beginReactiveTokenRefresh()
            case .revoked:
                await retirePairingAndFailRevoked()
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
        state = .connecting
        health = .unknown
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

            let expectedPairingGen = credentialStore.pairingGeneration
            let result = await tokenRefresher.refreshNow(pairing)
            guard running, !Task.isCancelled, authRefreshGeneration == generation,
                  credentialStore.pairingGeneration == expectedPairingGen else {
                return
            }

            switch result {
            case .refreshed(let updated):
                do {
                    try savePairing(updated)
                } catch {
                    splOwnerLog.error("reactive token refresh save failed: \(String(describing: type(of: error)), privacy: .public)")
                    await failWithKeychainUnavailable()
                    return
                }
                setCachedPairingOutcome(.loaded(updated))
                await disconnectCurrentTransport()
                guard running, !Task.isCancelled, authRefreshGeneration == generation else {
                    return
                }
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
                state = .connecting
                health = .unknown
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
                    guard running, !Task.isCancelled, authRefreshGeneration == generation else {
                        return
                    }
                    await connect()
                    return
                } else {
                    await retirePairingAndFailRevoked()
                    return
                }

            case .definitiveAuthFailure:
                await retirePairingAndFailRevoked()
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
            isTunnelManaged = !usableCandidates(for: pairing).isEmpty
            isPairedHome = Self.isHomePairing(pairing)
        case .absent:
            isTunnelManaged = false
            isPairedHome = false
        case .failed:
            // Preserve the previous signal on transient keychain load failures.
            break
        }
    }

    private func becomeDormant(tunnelManaged: Bool) {
        isTunnelManaged = tunnelManaged
        state = .disconnected
        health = .unknown
    }

    private func retirePairingAndFailRevoked() async {
        do {
            try deletePairing()
        } catch {
            splOwnerLog.error("pairing delete failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        setCachedPairingOutcome(.absent)
        await disconnectCurrentTransport()
        state = .error(.revoked)
        health = .unknown
    }

    private func failWithKeychainUnavailable() async {
        await disconnectCurrentTransport()
        state = .error(.keychainUnavailable)
        health = .unknown
    }

    private func failWithNotEntitled() async {
        await disconnectCurrentTransport()
        state = .error(.notEntitled)
        health = .unknown
    }

    private func disconnectCurrentTransport() async {
        journalVersion.disconnected()
        stopProbe()
        establishedLoopbackPort = nil
        stateObservationTask?.cancel()
        stateObservationTask = nil
        modeObservationTask?.cancel()
        modeObservationTask = nil
        let transport = self.transport
        self.transport = nil
        await transport?.disconnect()
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
