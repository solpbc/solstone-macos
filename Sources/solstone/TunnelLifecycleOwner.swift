// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
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

    static func live(_ refresher: DeviceTokenRefresher = DeviceTokenRefresher()) -> TunnelDeviceTokenRefreshing {
        TunnelDeviceTokenRefreshing(
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
@Observable
final class TunnelLifecycleOwner {
    private static let probeInterval: Duration = .seconds(30)
    private static let probeTimeout: Duration = .seconds(3)
    private static let loopbackRetryDelays: [Duration] = [.milliseconds(100), .milliseconds(300)]
    private static let establishmentRetryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(10), .seconds(30)]

    private(set) var state: TunnelLifecycleState = .disconnected
    private(set) var health: TunnelHealth = .unknown
    private(set) var isTunnelManaged = false
    private(set) var relayAccessStatus: PairingRelayAccessStatus = .noPairing

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
    private var establishedLoopbackPort: Int?
    @ObservationIgnored
    private var establishmentInFlight = false
    @ObservationIgnored
    private var currentPathSignature: NetworkPathSignature?
    @ObservationIgnored
    private var consecutiveProbeFailures = 0
    @ObservationIgnored
    private var running = false
    @ObservationIgnored
    private var cachedPairingOutcome: PairingLoadOutcome?

    init(
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLKeychain.load() },
        savePairing: @escaping @Sendable (StoredPairing) throws -> Void = { try SPLKeychain.save($0) },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLKeychain.delete() },
        tokenRefresher: TunnelDeviceTokenRefreshing = .live(),
        makeTransport: @escaping @MainActor @Sendable () -> any TunnelTransporting = { SPLTunnelTransport() },
        pathMonitoringSource: (any PathMonitoringSource)? = nil,
        probe: @escaping @Sendable (Int, Duration) async -> Bool = TunnelLifecycleOwner.httpStatusProbe(localPort:timeout:),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadPairing = loadPairing
        self.savePairing = savePairing
        self.deletePairing = deletePairing
        self.tokenRefresher = tokenRefresher
        self.makeTransport = makeTransport
        self.pathMonitor = pathMonitoringSource.map { PathMonitor(source: $0) } ?? PathMonitor()
        self.probe = probe
        self.sleep = sleep
        self.now = now
        refreshTunnelManagedFromStoredPairing()
    }

    static func dormantForSnapshot(
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLKeychain.load() }
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
        startPathMonitor()
        startTask = Task { @MainActor [weak self] in
            await self?.connectFromStoredPairing()
        }
    }

    func stop() async {
        running = false
        startTask?.cancel()
        startTask = nil
        cancelReactiveTokenRefresh()
        pathMonitor.stop()
        currentPathSignature = nil
        await disconnectCurrentTransport()
        state = .disconnected
        health = .unknown
    }

    func reevaluatePairing() async {
        invalidatePairingCache()
        guard running else {
            refreshTunnelManagedFromStoredPairing()
            return
        }

        let previous = startTask
        previous?.cancel()
        cancelReactiveTokenRefresh()
        startTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.running, !Task.isCancelled else {
                return
            }
            await self.disconnectCurrentTransport()
            await self.connectFromStoredPairing()
        }
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

    private func connectOnceForEstablishment() async -> EstablishmentOutcome {
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
                state = .connected(localPort: connection.localPort, via: connection.via)
                health = .unknown
                consecutiveProbeFailures = 0
                startProbe(localPort: connection.localPort)
                splOwnerLog.info("tunnel connected route=\(String(describing: connection.via), privacy: .public) local_port=\(connection.localPort, privacy: .public)")
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
            } catch SessionError.tokenExpired {
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
        let transport = makeTransport()
        self.transport = transport
        observe(transport)
        return transport
    }

    private func observe(_ transport: any TunnelTransporting) {
        stateObservationTask?.cancel()
        modeObservationTask?.cancel()

        stateObservationTask = Task { @MainActor [weak self] in
            for await tunnelState in transport.stateUpdates {
                await self?.handle(tunnelState)
            }
        }

        modeObservationTask = Task { @MainActor [weak self] in
            for await mode in transport.connectionModeUpdates {
                self?.handleConnectionMode(mode)
            }
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

        case .connecting, .tlsHandshaking:
            stopProbe()
            state = .connecting
            health = .unknown

        case .connected(let via):
            if let port = establishedLoopbackPort {
                state = .connected(localPort: port, via: Self.route(for: via))
                startProbe(localPort: port)
            } else if !establishmentInFlight {
                splOwnerLog.error("tunnel republished connected with no remembered loopback port")
            }

        case .failed(.tokenExpired):
            beginReactiveTokenRefresh()

        case .failed(.revoked):
            await retirePairingAndFailRevoked()

        case .failed(.notEntitled):
            await failWithNotEntitled()

        case .failed:
            stopProbe()
            state = .connecting
            health = .unknown
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

        launchReactiveTokenRefresh()
    }

    private func launchReactiveTokenRefresh() {
        pendingReactiveRefresh = false
        stopProbe()
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

            let result = await tokenRefresher.refreshNow(pairing)
            guard running, !Task.isCancelled else {
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
                guard running, !Task.isCancelled else {
                    return
                }
                pendingReactiveRefresh = false
                await connect()
                guard running, !Task.isCancelled else {
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

            case .notNeeded, .definitiveAuthFailure:
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

    private func startProbe(localPort: Int) {
        guard probeTask == nil else {
            return
        }
        probeTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await self.sleep(Self.probeInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.localPort == localPort else {
                    return
                }
                await self.runProbe(localPort: localPort)
            }
        }
    }

    private func stopProbe() {
        probeTask?.cancel()
        probeTask = nil
        consecutiveProbeFailures = 0
    }

    private func runProbe(localPort: Int) async {
        guard let transport else {
            return
        }
        let before = await transport.inboundActivitySnapshot()
        let succeeded = await probe(localPort, Self.probeTimeout)
        if succeeded {
            consecutiveProbeFailures = 0
            health = .healthy
            return
        }

        let after = await transport.inboundActivitySnapshot()
        guard after == before else {
            consecutiveProbeFailures = 0
            health = .healthy
            return
        }

        consecutiveProbeFailures += 1
        if consecutiveProbeFailures >= 2 {
            health = .degraded
        }
        if consecutiveProbeFailures >= 3 {
            consecutiveProbeFailures = 0
            await transport.requestReconnect()
        }
    }

    private func usableCandidates(for pairing: StoredPairing) -> [TransportEndpoint] {
        TransportEndpoint.candidates(for: pairing).filter { candidate in
            switch candidate {
            case .lan(let host, let port, _):
                return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && 1...65535 ~= port
            case .relay(let endpoint, let instanceID, let deviceToken):
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
        relayAccessStatus = Self.relayAccessStatus(for: outcome, preserving: relayAccessStatus)
    }

    private static func relayAccessStatus(
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

    private static func relayAccessStatus(for pairing: StoredPairing) -> PairingRelayAccessStatus {
        switch pairing.relayEnrollment {
        case .enrolled:
            return .available
        case .unavailable:
            return .unavailable
        }
    }

    private func invalidatePairingCache() {
        cachedPairingOutcome = nil
    }

    private func refreshTunnelManagedFromStoredPairing() {
        switch loadPairingCached() {
        case .loaded(let pairing):
            isTunnelManaged = !usableCandidates(for: pairing).isEmpty
        case .absent:
            isTunnelManaged = false
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
        isTunnelManaged = false
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

    private static func httpStatusProbe(localPort: Int, timeout: Duration) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/app/network/api/status") else {
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

private enum EstablishmentOutcome: Sendable {
    case connected
    case dormant
    case terminal
    case retry
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
