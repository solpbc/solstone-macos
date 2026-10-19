// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import Observation
import os
import SolstoneCore

@MainActor
@Observable
final class SetupModel {
    let enabled: Bool
    let continuationStore: SetupContinuationStore
    let mailboxStore: SetupMailboxStore
    let freshFlow: FreshJournalFlow
    weak var appState: AppState?
    let downloadProgress: SetupDownloadProgress

    private let resolveIdentityOverride: (@Sendable (String, String?) async -> JournalIdentityResolution)?
    private let sleepDuration: Duration
    private let requestMicrophone: @MainActor () async -> Void
    private let requestScreen: @MainActor () -> Void
    private let bringSolstoneToFront: @MainActor () -> Void

    private(set) var continuation: SetupContinuation?
    private(set) var isPeerSupportingSetup: Bool = false
    private(set) var acknowledgementError: String?
    private(set) var finalOpenError: String?
    private(set) var ownerPairingError: String?
    private(set) var journalPollingText: String?
    private(set) var journalPollingError: String?

    var journalPollingOffersJournalAppDownload: Bool {
        journalPollingError == UICopy.SETUP_COULDNT_INSTALL_JOURNAL_APP
    }
    var olderDiscoveredMark: JournalMark?

    enum ConnectionStepState: Equatable {
        case idle
        case connecting
        case failed(String)
        case connected(JournalMark)
    }
    private(set) var connectionStepState: ConnectionStepState = .idle

    public static func isSupporting(continuation: SetupContinuation?) -> Bool {
        guard let continuation, continuation.phase != nil, !continuation.completed else { return false }
        return continuation.mode == .supporting && continuation.accepted?.isValid == true
    }

    @ObservationIgnored
    private var journalPollingTask: Task<Void, Never>?
    @ObservationIgnored
    private var connectionTask: Task<Void, Never>?
    @ObservationIgnored
    private var currentConnectionTaskID: UUID?
    @ObservationIgnored
    private var currentConnectingHandoffID: UUID?
    @ObservationIgnored
    private var retryAfterConnection = false
    @ObservationIgnored
    private var bringFrontAfterPairingDial = false
    @ObservationIgnored
    private var bringFrontAfterSupportingConnection = false
    @ObservationIgnored
    private var finalOpenInFlight = false
    private(set) var journalOpenedPendingCompletion = false

    private(set) var phase: SetupPhase?

    @discardableResult
    internal func setPhase(_ newPhase: SetupPhase?) -> Bool {
        guard enabled else { return false }
        var cont = continuation ?? SetupContinuation()
        if let newPhase {
            cont.phase = newPhase
            cont.completed = false
            do {
                try continuationStore.save(cont)
                self.continuation = cont
                self.isPeerSupportingSetup = Self.isSupporting(continuation: cont)
                self.phase = newPhase
                if newPhase == .journal {
                    startJournalPhase()
                } else {
                    stopJournalPolling()
                }
                reconcileSupportingTasks()
                return true
            } catch {
                return false
            }
        } else {
            cont.phase = nil
            cont.completed = true
            do {
                try continuationStore.save(cont)
                self.continuation = cont
                self.isPeerSupportingSetup = Self.isSupporting(continuation: cont)
                self.phase = nil
                stopJournalPolling()
                stopSupportingTasks()
                return true
            } catch {
                return false
            }
        }
    }

    @discardableResult
    public func switchToOwnerComparison() -> Bool {
        guard enabled else { return false }
        ownerPairingError = nil
        guard phase != nil else { return true }
        guard var cont = continuation else { return false }
        cont.mode = .ownerComparison
        do {
            try continuationStore.save(cont)
            self.continuation = cont
            self.isPeerSupportingSetup = Self.isSupporting(continuation: cont)
            self.connectionStepState = .idle
            stopJournalPolling()
            stopSupportingTasks()
            return true
        } catch {
            ownerPairingError = UICopy.SETUP_COULDNT_FINISH
            return false
        }
    }

    public init(
        enabled: Bool = false,
        continuationStore: SetupContinuationStore,
        mailboxStore: SetupMailboxStore,
        freshFlow: FreshJournalFlow,
        resolveIdentity: (@Sendable (String, String?) async -> JournalIdentityResolution)? = nil,
        sleepDuration: Duration = .seconds(2),
        requestMicrophone: @escaping @MainActor () async -> Void = { await PermissionChecker().requestMicrophone() },
        requestScreen: @escaping @MainActor () -> Void = { PermissionChecker().promptScreenRecording() },
        bringSolstoneToFront: @escaping @MainActor () -> Void = {},
        downloadProgress: SetupDownloadProgress? = nil,
        appState: AppState? = nil
    ) {
        self.enabled = enabled
        self.continuationStore = continuationStore
        self.mailboxStore = mailboxStore
        self.freshFlow = freshFlow
        self.resolveIdentityOverride = resolveIdentity
        self.sleepDuration = sleepDuration
        self.requestMicrophone = requestMicrophone
        self.requestScreen = requestScreen
        self.bringSolstoneToFront = bringSolstoneToFront
        self.appState = appState
        self.downloadProgress = downloadProgress ?? SetupDownloadProgress()

        let loaded = enabled ? continuationStore.load() : nil
        self.continuation = loaded
        self.phase = loaded?.phase
        self.isPeerSupportingSetup = Self.isSupporting(continuation: loaded)
    }

    public convenience init(
        enabled: Bool = false,
        continuationStore: SetupContinuationStore? = nil,
        mailboxDirectory: URL,
        freshFlow: FreshJournalFlow? = nil,
        resolveIdentity: (@Sendable (String, String?) async -> JournalIdentityResolution)? = nil,
        sleepDuration: Duration = .seconds(2),
        requestMicrophone: @escaping @MainActor () async -> Void = { await PermissionChecker().requestMicrophone() },
        requestScreen: @escaping @MainActor () -> Void = { PermissionChecker().promptScreenRecording() },
        bringSolstoneToFront: @escaping @MainActor () -> Void = {},
        downloadProgress: SetupDownloadProgress? = nil,
        appState: AppState? = nil
    ) {
        let store = continuationStore ?? SetupContinuationStore(directory: mailboxDirectory)
        let mailbox = SetupMailboxStore(directory: mailboxDirectory)
        let flow = freshFlow ?? FreshJournalFlow(dependencies: .inert())
        self.init(
            enabled: enabled,
            continuationStore: store,
            mailboxStore: mailbox,
            freshFlow: flow,
            resolveIdentity: resolveIdentity,
            sleepDuration: sleepDuration,
            requestMicrophone: requestMicrophone,
            requestScreen: requestScreen,
            bringSolstoneToFront: bringSolstoneToFront,
            downloadProgress: downloadProgress,
            appState: appState
        )
    }

    public func attach(_ appState: AppState) {
        self.appState = appState
    }

    public func activate() {
        guard enabled else { return }
        if phase == .journal {
            startJournalPhase()
        }
        reconcileSupportingTasks()
    }

    func ingestStep5IfNeeded() {
        guard enabled else { return }
        let load = mailboxStore.loadStep5()
        switch load {
        case .missing:
            if let snapshot = continuation?.accepted {
                do {
                    let result = try mailboxStore.commitStep5(
                        loadedID: snapshot.handoffID,
                        alreadyAccepted: true,
                        pairingBlocksNewAcceptance: true,
                        storeProgress: {}
                    )
                    try requireAcknowledged(result)
                } catch {
                    self.acknowledgementError = UICopy.SETUP_ACKNOWLEDGEMENT_FAILED
                }
            }
        case .malformed:
            break
        case .ready(let handoff):
            let held = appState?.tunnelLifecycleOwner.sameMachineStoredPairingState ?? .noneHeld
            let currentSnapshot = continuation?.accepted
            let alreadyAccepted = (currentSnapshot?.handoffID == handoff.handoffID)
            let currentPhase = self.phase
            let currentMode = continuation?.mode

            let pairingBlocks = !alreadyAccepted && (held != .noneHeld)

            let handoffID = handoff.handoffID
            let rootPath = handoff.journalRootPath ?? ""
            let instanceID = handoff.expectedInstanceID ?? ""
            let fingerprint = handoff.expectedCAFingerprint ?? ""

            do {
                let result = try mailboxStore.commitStep5(
                    loadedID: handoffID,
                    alreadyAccepted: alreadyAccepted,
                    pairingBlocksNewAcceptance: pairingBlocks,
                    storeProgress: { [weak self] in
                        guard let self else { throw SetupMailboxError.continuationInProgress }
                        if currentMode == .ownerComparison {
                            throw SetupMailboxError.continuationInProgress
                        }
                        if currentPhase == .microphone || currentPhase == .screen || currentPhase == .connection {
                            if let snap = currentSnapshot, snap.handoffID == handoffID {
                                // duplicate during later phase is fine
                            } else {
                                throw SetupMailboxError.continuationInProgress
                            }
                        }
                        if let snap = currentSnapshot, snap.handoffID != handoffID {
                            throw SetupMailboxError.continuationInProgress
                        }
                        guard alreadyAccepted || (currentPhase == .journal && held == .noneHeld && currentSnapshot == nil) else {
                            throw SetupMailboxError.continuationInProgress
                        }
                        let snapshot = SetupAcceptedStep5Snapshot(
                            handoffID: handoffID,
                            journalRootPath: rootPath,
                            expectedInstanceID: instanceID,
                            expectedCAFingerprint: fingerprint
                        )
                        guard snapshot.isValid else {
                            throw SetupMailboxError.malformedPayload
                        }
                        var cont = self.continuation ?? SetupContinuation()
                        cont.accepted = snapshot
                        cont.mode = .supporting
                        if cont.phase == nil || cont.phase == .journal {
                            cont.phase = .microphone
                        }
                        try self.continuationStore.save(cont)
                    }
                )

                try requireAcknowledged(result)
                if let loaded = self.continuationStore.load() {
                    self.continuation = loaded
                    self.isPeerSupportingSetup = Self.isSupporting(continuation: loaded)
                    if self.phase == .journal && loaded.phase != .journal {
                        self.phase = loaded.phase
                        stopJournalPolling()
                        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                        bringSolstoneToFront()
                        bringFrontAfterSupportingConnection = true
                    }
                }
            } catch {
                self.acknowledgementError = UICopy.SETUP_ACKNOWLEDGEMENT_FAILED
                if let loaded = self.continuationStore.load() {
                    self.continuation = loaded
                    self.isPeerSupportingSetup = Self.isSupporting(continuation: loaded)
                    if self.phase == .journal && loaded.phase != .journal {
                        self.phase = loaded.phase
                        stopJournalPolling()
                        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                        bringSolstoneToFront()
                        bringFrontAfterSupportingConnection = true
                    }
                }
            }
        }
        reconcileSupportingTasks()
    }

    private func requireAcknowledged(_ result: SetupCommitResult) throws {
        switch result {
        case .accepted, .republished:
            acknowledgementError = nil
        case .lockTimeout:
            throw SetupMailboxError.lockTimeout
        case .noHandoff, .rejected:
            throw SetupMailboxError.continuationInProgress
        }
    }

    /// Refresh after the OS prompt and on activation after visiting System Settings.
    /// A running session freezes its sources, so a newly granted source needs reconciliation.
    public func reconcileSourcePermissions() async {
        guard enabled, let appState else { return }
        await appState.capture.checkPermissionsAndAutoStart()
        // Turn-on clears the old stop before prompting. A newer Stop during either await wins.
        if appState.capture.isExplicitlyStopped || appState.capture.isUserStopped { return }
        await appState.applySelectedSourcesToRunningSession()
    }

    @discardableResult
    public func turnOnMicrophone() -> Task<Void, Never> {
        guard enabled else { return Task {} }
        if let appState {
            appState.capture.clearOwnerStop()
            var config = appState.config
            config.isMicrophoneCaptureEnabled = true
            appState.updateConfig(config)
        }
        return Task {
            await requestMicrophone()
            await reconcileSourcePermissions()
        }
    }

    @discardableResult
    public func notNowMicrophone() -> Task<Void, Never> {
        guard enabled else { return Task {} }
        if let appState {
            var config = appState.config
            config.isMicrophoneCaptureEnabled = false
            appState.updateConfig(config)
        }
        setPhase(.screen)
        return Task { await reconcileSourcePermissions() }
    }

    public func continueFromMicrophone() {
        setPhase(.screen)
    }

    @discardableResult
    public func turnOnScreen() -> Task<Void, Never> {
        guard enabled else { return Task {} }
        if let appState {
            appState.capture.clearOwnerStop()
            var config = appState.config
            config.isScreenCaptureEnabled = true
            appState.updateConfig(config)
        }
        requestScreen()
        return Task { await reconcileSourcePermissions() }
    }

    @discardableResult
    public func notNowScreen() -> Task<Void, Never> {
        guard enabled else { return Task {} }
        if let appState {
            var config = appState.config
            config.isScreenCaptureEnabled = false
            appState.updateConfig(config)
        }
        setPhase(.connection)
        return Task { await reconcileSourcePermissions() }
    }

    public func continueFromScreen() {
        setPhase(.connection)
    }

    public func prepareScreenRestart(requestRestart: () -> Void) {
        guard setPhase(.screen) else { return }
        if let appState {
            var config = appState.config
            config.isScreenCaptureEnabled = true
            appState.updateConfig(config)
        }
        requestRestart()
    }

    public func startConnectionPhase() {
        guard canRunSupportingConnection else { return }
        if isPeerSupportingSetup {
            performSupportingConnection(forceRestart: false)
        }
    }

    public func handleTunnelConnected() {
        guard canRunSupportingConnection else { return }
        if connectionTask != nil {
            // Let a first pairing finish; the edge can arrive during its own activation.
            retryAfterConnection = true
        } else {
            startConnectionPhase()
        }
    }

    internal func armBringFrontAfterPairingDial() {
        bringFrontAfterPairingDial = true
    }

    internal func bringFrontIfPairingDialSettled(_ state: TunnelLifecycleState) {
        guard bringFrontAfterPairingDial else { return }
        switch state {
        case .connected, .error:
            bringFrontAfterPairingDial = false
            bringSolstoneToFront()
        case .connecting, .disconnected:
            break
        }
    }

    public func retryConnection() {
        if isPeerSupportingSetup {
            performSupportingConnection(forceRestart: true)
        }
    }

    private func publishConnectionStepState(_ newState: ConnectionStepState) {
        self.connectionStepState = newState
        if bringFrontAfterSupportingConnection {
            switch newState {
            case .connected, .failed:
                bringFrontAfterSupportingConnection = false
                bringSolstoneToFront()
            case .connecting, .idle:
                break
            }
        }
    }

    public func performSupportingConnection(forceRestart: Bool = false) {
        guard canRunSupportingConnection, let appState, !appState.isTerminating else { return }
        guard let accepted = continuation?.accepted,
              accepted.isValid else {
            publishConnectionStepState(.failed(UICopy.SETUP_COULDNT_VERIFY_MARK))
            return
        }
        if !forceRestart && connectionTask != nil && currentConnectingHandoffID == accepted.handoffID {
            return
        }
        connectionTask?.cancel()
        if let old = currentConnectingHandoffID {
            appState.pairingCoordinator.cancelSupportingPairing(handoffID: old)
        }
        let taskID = UUID()
        currentConnectionTaskID = taskID
        currentConnectingHandoffID = accepted.handoffID
        publishConnectionStepState(.connecting)
        retryAfterConnection = false

        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.currentConnectionTaskID == taskID {
                    self.connectionTask = nil
                    self.currentConnectionTaskID = nil
                    let shouldRetry = self.retryAfterConnection
                    self.retryAfterConnection = false
                    if shouldRetry, case .failed = self.connectionStepState {
                        self.startConnectionPhase()
                    }
                }
            }
            let outcome = await appState.verifySupportingConnectionFromHandoff(
                expectedHandoffID: accepted.handoffID,
                expectedInstanceID: accepted.expectedInstanceID,
                expectedCAFingerprint: accepted.expectedCAFingerprint,
                operationIsCurrent: { [weak self] in
                    guard let self else { return false }
                    return !Task.isCancelled && self.canRunSupportingConnection &&
                        self.currentConnectionTaskID == taskID && self.continuation?.accepted == accepted
                }
            )
            guard !Task.isCancelled, self.currentConnectionTaskID == taskID,
                  self.canRunSupportingConnection, self.continuation?.accepted == accepted else { return }
            switch outcome {
            case .recorded(let mark):
                self.publishConnectionStepState(.connected(mark))
            case .alreadyRecorded:
                if let confirmed = appState.confirmedMark {
                    self.publishConnectionStepState(.connected(confirmed))
                } else {
                    self.publishConnectionStepState(.failed(UICopy.SETUP_COULDNT_VERIFY_MARK))
                }
            case .stillSettingUp:
                self.publishConnectionStepState(.failed(UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP))
            case .notEligible, .pairStartFailed, .linkRejected, .fingerprintOrPinMismatch,
                 .ceremonyFailed, .durableInstanceMismatch, .fetchAbsent, .fetchFailed, .recordFailed:
                self.publishConnectionStepState(.failed(UICopy.SETUP_COULDNT_VERIFY_MARK))
            }
        }
    }

    private var canRunSupportingConnection: Bool {
        enabled && isPeerSupportingSetup &&
            (phase == .microphone || phase == .screen || phase == .connection) &&
            appState?.isTerminating != true
    }

    private func reconcileSupportingTasks() {
        guard canRunSupportingConnection else { stopSupportingTasks(); return }
        if currentConnectingHandoffID != continuation?.accepted?.handoffID {
            startConnectionPhase()
        }
        downloadProgress.start(
            admission: { [weak self] in await self?.downloadAdmission() },
            verifyDirect: { [weak self] in await self?.directListenerMatches($0) ?? false }
        )
    }

    func performDownloadAction(_ action: SetupDownloadAction) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.downloadProgress.perform(
                action,
                admission: { [weak self] in await self?.downloadAdmission() },
                verifyDirect: { [weak self] in await self?.directListenerMatches($0) ?? false }
            )
        }
    }

    /// The same check the final open makes: the tunnel names the accepted journal,
    /// then Journal.app's direct listener names the same committed identity.
    private func directListenerMatches(_ context: SetupDownloadAdmission) async -> Bool {
        guard let accepted = continuation?.accepted, accepted.handoffID == context.handoffID else { return false }
        let expectedInstanceID = accepted.expectedInstanceID
        return await Self.verifyJournalIdentity(
            expectedInstanceID: expectedInstanceID,
            includeDirect: true,
            checkAdmission: { [weak self] in
                self?.supportingIdentityAdmitted(expectedInstanceID: expectedInstanceID,
                                                 revision: context.credential) ?? false
            },
            fetchTunnelIdentity: { [weak self] in
                await self?.fetchTunnelIdentity(expectedInstanceID: expectedInstanceID) ?? .absent
            },
            fetchDirectIdentity: { await Self.fetchDirectIdentity(expectedInstanceID: expectedInstanceID) }
        )
    }

    private func supportingIdentityAdmitted(expectedInstanceID: String, revision: PairingCredentialRevision) -> Bool {
        guard let appState, case .connected = appState.tunnelLifecycleOwner.state,
              let pairing = appState.currentDurablePairing,
              pairing.instanceID == expectedInstanceID,
              appState.currentDurablePairingRevision == revision,
              let snapshot = continuation?.accepted,
              snapshot.expectedInstanceID == expectedInstanceID else { return false }
        return caChainContainsFingerprint(caChainPEM: pairing.caChainPEM,
                                          expectedLowerHex: snapshot.expectedCAFingerprint)
    }

    private func fetchTunnelIdentity(expectedInstanceID: String) async -> JournalIdentityResolution {
        guard let appState, let tunnelBase = tunnelIdentityBase(state: appState.tunnelLifecycleOwner.state) else {
            return .absent
        }
        let fetcher = JournalIdentityFetcher(prepareRequest: { $0.attachLoopbackCapability() })
        return await fetcher.resolveIdentity(baseURL: tunnelBase, expectedInstanceID: expectedInstanceID)
    }

    private static func fetchDirectIdentity(expectedInstanceID: String) async -> JournalIdentityResolution {
        await JournalIdentityFetcher().resolveIdentity(baseURL: "http://127.0.0.1:5015",
                                                       expectedInstanceID: expectedInstanceID)
    }

    func stopSupportingTasks() {
        if let handoffID = currentConnectingHandoffID {
            appState?.pairingCoordinator.cancelSupportingPairing(handoffID: handoffID)
        }
        currentConnectingHandoffID = nil
        connectionTask?.cancel()
        connectionTask = nil
        currentConnectionTaskID = nil
        retryAfterConnection = false
        downloadProgress.invalidate()
    }

    func handleDownloadRouteChanged() {
        downloadProgress.invalidate()
        reconcileSupportingTasks()
    }

    private func downloadAdmission() async -> SetupDownloadAdmission? {
        guard canRunSupportingConnection, let accepted = continuation?.accepted,
              let appState, appState.isJournalMarkConfirmed, appState.confirmedMark != nil,
              let revision = appState.currentDurablePairingRevision,
              let pairing = appState.currentDurablePairing,
              pairing.instanceID == accepted.expectedInstanceID,
              caChainContainsFingerprint(caChainPEM: pairing.caChainPEM,
                                         expectedLowerHex: accepted.expectedCAFingerprint) else { return nil }
        let generation = appState.journalHomeBaseChangeToken
        let resolved = await appState.resolveHomeBase()
        guard canRunSupportingConnection, continuation?.accepted == accepted,
              appState.currentDurablePairingRevision == revision,
              appState.isJournalMarkConfirmed, appState.confirmedMark != nil,
              appState.journalHomeBaseChangeToken == generation,
              !appState.tunnelLifecycleOwner.ordinaryRouteRevoked,
              case .url(let base) = resolved,
              base == tunnelIdentityBase(state: appState.tunnelLifecycleOwner.state) else { return nil }
        return SetupDownloadAdmission(handoffID: accepted.handoffID, credential: revision,
                                      routeGeneration: generation, baseURL: base)
    }

    public func continueFromOlderJournal() {
        guard let appState else { return }
        guard appState.isJournalMarkConfirmed,
              appState.currentDurablePairingAdmissionIsReady else {
            return
        }
        setPhase(.microphone)
    }

    private var journalPairingLinkHeld = false

    private var blocksOnPairingLink: Bool {
        journalPairingLinkHeld || appState?.pendingPairingLink != nil
    }

    internal func setJournalPairingLinkHeld(_ held: Bool) {
        journalPairingLinkHeld = held
        if held {
            stopJournalPolling()
            journalPollingText = nil
            journalPollingError = nil
        }
    }

    private var canRunJournalPhase: Bool {
        phase == .journal && continuation?.mode != .ownerComparison
    }

    public func startJournalPhase() {
        guard canRunJournalPhase else { return }
        journalPollingTask?.cancel()
        journalPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.canRunJournalPhase, !Task.isCancelled else { return }
            if self.blocksOnPairingLink {
                self.journalPollingText = nil
                self.journalPollingError = nil
                return
            }
            // Automatic setup must not call resolveTrustedJournal when this is nil:
            // that function's else branch acquires.
            let trustedURL = await self.freshFlow.trustedInstalledJournalURL()
            guard self.canRunJournalPhase, !Task.isCancelled else { return }
            if self.blocksOnPairingLink {
                self.journalPollingText = nil
                self.journalPollingError = nil
                return
            }
            guard let trustedURL else {
                self.journalPollingText = nil
                self.journalPollingError = nil
                return
            }
            self.journalPollingText = UICopy.SETUP_OPENING_YOUR_JOURNAL
            self.journalPollingError = nil
            await self.continueJournalPhase(journalURL: trustedURL)
        }
    }

    public func stopJournalPolling() {
        journalPollingTask?.cancel()
        journalPollingTask = nil
    }

    public func retryJournalPhase() {
        guard canRunJournalPhase else { return }
        journalPollingTask?.cancel()
        journalPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runJournalPhase()
        }
    }

    private func resolveIdentity(baseURL: String, expectedInstanceID: String?) async -> JournalIdentityResolution {
        if let override = resolveIdentityOverride {
            return await override(baseURL, expectedInstanceID)
        }
        let fetcher = JournalIdentityFetcher(prepareRequest: { $0.attachLoopbackCapability() })
        return await fetcher.resolveIdentity(baseURL: baseURL, expectedInstanceID: expectedInstanceID)
    }

    internal func runJournalPhase() async {
        guard canRunJournalPhase, !Task.isCancelled else { return }
        if blocksOnPairingLink {
            journalPollingText = nil
            journalPollingError = nil
            return
        }
        journalPollingText = UICopy.SETUP_OPENING_YOUR_JOURNAL
        journalPollingError = nil

        let journalURL: URL
        do {
            journalURL = try await freshFlow.resolveTrustedJournal()
        } catch let failure as JournalHandoffFailure {
            journalPollingText = nil
            switch failure {
            case .applicationsDirectoryUnwritable:
                journalPollingError = UICopy.SETUP_COULDNT_INSTALL_JOURNAL_APP
            case .runningJournalWouldNotQuit:
                journalPollingError = failure.ownerMessage
            default:
                journalPollingError = UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL
            }
            return
        } catch {
            journalPollingText = nil
            journalPollingError = UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL
            return
        }

        guard canRunJournalPhase, !Task.isCancelled else { return }
        if blocksOnPairingLink {
            journalPollingText = nil
            journalPollingError = nil
            return
        }

        await continueJournalPhase(journalURL: journalURL)
    }

    private func continueJournalPhase(journalURL: URL) async {
        guard let bundle = Bundle(url: journalURL) else {
            journalPollingText = nil
            journalPollingError = UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL
            return
        }

        let capabilities = bundle.object(forInfoDictionaryKey: "SolstoneSetupCapabilities")
        let isSupporting = journalSupportsSetupSequence(capabilities)

        if isSupporting {
            var cont = continuation ?? SetupContinuation(phase: .journal)
            let outboundID: UUID
            if let existing = cont.pendingOutboundStep1ID {
                outboundID = existing
            } else {
                let newID = UUID()
                cont.pendingOutboundStep1ID = newID
                do {
                    try continuationStore.save(cont)
                    self.continuation = cont
                } catch {
                    journalPollingText = nil
                    journalPollingError = UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL
                    return
                }
                outboundID = newID
            }

            do {
                try mailboxStore.writeStep1(handoffID: outboundID)
            } catch {
                journalPollingText = nil
                journalPollingError = UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL
                return
            }

            do {
                try await freshFlow.launchTrustedJournal(at: journalURL)
            } catch {
                journalPollingText = nil
                journalPollingError = UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL
                return
            }

            journalPollingText = UICopy.SETUP_OPENING_YOUR_JOURNAL
            journalPollingError = nil

            while !Task.isCancelled && canRunJournalPhase && !blocksOnPairingLink {
                if let receipt = try? mailboxStore.readStep1Receipt() {
                    if var currentCont = self.continuation, currentCont.pendingOutboundStep1ID == receipt.handoffID {
                        currentCont.pendingOutboundStep1ID = nil
                        if (try? continuationStore.save(currentCont)) != nil {
                            self.continuation = currentCont
                        }
                    }
                }

                ingestStep5IfNeeded()
                if phase != .journal {
                    break
                }

                let resolution = await resolveIdentity(baseURL: ServiceMode.bundledServiceURL, expectedInstanceID: nil)
                switch resolution {
                case .uncommitted:
                    journalPollingText = UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP
                    journalPollingError = nil
                case .absent:
                    journalPollingText = UICopy.SETUP_OPENING_YOUR_JOURNAL
                    journalPollingError = nil
                case .failed:
                    journalPollingText = nil
                    journalPollingError = UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL
                case .mark:
                    journalPollingText = UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP
                    journalPollingError = nil
                }

                do {
                    try await Task.sleep(for: sleepDuration)
                } catch {
                    break
                }
            }
            if blocksOnPairingLink {
                journalPollingText = nil
                journalPollingError = nil
            }
        } else {
            do {
                try await freshFlow.launchTrustedJournal(at: journalURL)
            } catch {
                journalPollingText = nil
                journalPollingError = UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL
                return
            }

            journalPollingText = UICopy.SETUP_OPENING_YOUR_JOURNAL
            journalPollingError = nil

            while !Task.isCancelled && canRunJournalPhase && !blocksOnPairingLink {
                let resolution = await resolveIdentity(baseURL: ServiceMode.bundledServiceURL, expectedInstanceID: nil)
                switch resolution {
                case .mark(let mark, _):
                    olderDiscoveredMark = mark
                    journalPollingText = nil
                    journalPollingError = nil
                    return
                case .uncommitted:
                    journalPollingText = UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP
                    journalPollingError = nil
                case .absent:
                    journalPollingText = UICopy.SETUP_OPENING_YOUR_JOURNAL
                    journalPollingError = nil
                case .failed:
                    journalPollingText = nil
                    journalPollingError = UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL
                }

                do {
                    try await Task.sleep(for: sleepDuration)
                } catch {
                    break
                }
            }
            if blocksOnPairingLink {
                journalPollingText = nil
                journalPollingError = nil
            }
        }
    }

    /// The tunnel's committed identity must name the expected journal; with `includeDirect`,
    /// the direct listener's must match it. A destination-consistency check, not proof.
    static func verifyJournalIdentity(
        expectedInstanceID: String,
        expectedMark: JournalMark? = nil,
        includeDirect: Bool,
        checkAdmission: () -> Bool,
        fetchTunnelIdentity: () async -> JournalIdentityResolution,
        fetchDirectIdentity: () async -> JournalIdentityResolution
    ) async -> Bool {
        let tunnelRes = await fetchTunnelIdentity()
        guard checkAdmission() else { return false }
        guard case .mark(let tunnelMark, let tunnelInstanceID) = tunnelRes,
              tunnelInstanceID == expectedInstanceID else { return false }
        if let expectedMark, tunnelMark != expectedMark { return false }
        guard includeDirect else { return true }

        let directRes = await fetchDirectIdentity()
        guard checkAdmission() else { return false }
        guard case .mark(let directMark, let directInstanceID) = directRes,
              directInstanceID == expectedInstanceID else { return false }
        return directMark == (expectedMark ?? tunnelMark)
    }

    @MainActor
    private func executeSetupFinalOpenCore(
        expectedInstanceID: String,
        expectedMark: JournalMark? = nil,
        isOlderPeer: Bool = false,
        isRemotePeer: Bool = false,
        openPairedJournal: () -> Bool = { false },
        checkAdmission: () -> Bool,
        fetchTunnelIdentity: () async -> JournalIdentityResolution,
        fetchDirectIdentity: () async -> JournalIdentityResolution,
        openURL: (URL) -> Bool,
        persistFinish: () -> Bool
    ) async -> Bool {
        if journalOpenedPendingCompletion {
            if persistFinish() {
                journalOpenedPendingCompletion = false
                return true
            }
            return false
        }

        if isOlderPeer && expectedMark == nil {
            return false
        }

        guard checkAdmission() else {
            return false
        }

        guard await Self.verifyJournalIdentity(
            expectedInstanceID: expectedInstanceID,
            expectedMark: isOlderPeer ? expectedMark : nil,
            includeDirect: !isRemotePeer,
            checkAdmission: checkAdmission,
            fetchTunnelIdentity: fetchTunnelIdentity,
            fetchDirectIdentity: fetchDirectIdentity
        ) else { return false }

        if isRemotePeer {
            guard checkAdmission(), openPairedJournal() else { return false }
        } else {
            guard checkAdmission(),
                  let targetURL = URL(string: "http://127.0.0.1:5015/"),
                  openURL(targetURL) else { return false }
        }

        journalOpenedPendingCompletion = true
        if persistFinish() {
            journalOpenedPendingCompletion = false
            return true
        } else {
            return false
        }
    }

    @MainActor
    internal func executeSetupFinalOpen(
        expectedInstanceID: String,
        expectedMark: JournalMark? = nil,
        isOlderPeer: Bool = false,
        isRemotePeer: Bool = false,
        openPairedJournal: () -> Bool = { false },
        checkAdmission: () -> Bool,
        fetchTunnelIdentity: () async -> JournalIdentityResolution,
        fetchDirectIdentity: () async -> JournalIdentityResolution,
        openURL: (URL) -> Bool,
        persistFinish: () -> Bool
    ) async -> Bool {
        if finalOpenInFlight { return false }
        finalOpenInFlight = true
        defer { finalOpenInFlight = false }

        return await executeSetupFinalOpenCore(
            expectedInstanceID: expectedInstanceID,
            expectedMark: expectedMark,
            isOlderPeer: isOlderPeer,
            isRemotePeer: isRemotePeer,
            openPairedJournal: openPairedJournal,
            checkAdmission: checkAdmission,
            fetchTunnelIdentity: fetchTunnelIdentity,
            fetchDirectIdentity: fetchDirectIdentity,
            openURL: openURL,
            persistFinish: persistFinish
        )
    }

    public func performSetupFinalOpen() {
        guard enabled else { return }
        guard let appState else { return }
        guard !finalOpenInFlight else { return }
        finalOpenInFlight = true
        finalOpenError = nil

        if journalOpenedPendingCompletion {
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finalOpenInFlight = false }
                if self.setPhase(nil) {
                    self.journalOpenedPendingCompletion = false
                    self.finalOpenError = nil
                } else {
                    self.finalOpenError = UICopy.SETUP_COULDNT_FINISH
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finalOpenInFlight = false }
            let expectedInstanceID: String
            let expectedMark: JournalMark?
            let snapshotRevision: PairingCredentialRevision

            if self.isPeerSupportingSetup {
                guard let snapshot = self.continuation?.accepted,
                      let pairing = appState.currentDurablePairing,
                      pairing.instanceID == snapshot.expectedInstanceID,
                      caChainContainsFingerprint(caChainPEM: pairing.caChainPEM, expectedLowerHex: snapshot.expectedCAFingerprint),
                      appState.isJournalMarkConfirmed,
                      let mark = appState.confirmedMark,
                      let rev = appState.currentDurablePairingRevision,
                      appState.currentDurablePairingAdmissionIsReady else {
                    self.finalOpenError = UICopy.SETUP_COULDNT_FINISH
                    return
                }
                expectedInstanceID = snapshot.expectedInstanceID
                expectedMark = mark
                snapshotRevision = rev
            } else {
                guard appState.isJournalMarkConfirmed,
                      let mark = appState.confirmedMark,
                      let pairing = appState.currentDurablePairing,
                      let rev = appState.currentDurablePairingRevision,
                      appState.currentDurablePairingAdmissionIsReady else {
                    self.finalOpenError = UICopy.SETUP_COULDNT_FINISH
                    return
                }
                expectedInstanceID = pairing.instanceID
                expectedMark = mark
                snapshotRevision = rev
            }

            let isOlderPeer = !self.isPeerSupportingSetup

            let success = await self.executeSetupFinalOpenCore(
                expectedInstanceID: expectedInstanceID,
                expectedMark: expectedMark,
                isOlderPeer: isOlderPeer,
                isRemotePeer: self.continuation?.mode == .ownerComparison,
                openPairedJournal: { [weak appState] in
                    guard let appState else { return false }
                    appState.openJournalWindowDirectly()
                    return appState.openSceneIds.contains(.journal)
                },
                checkAdmission: { [weak self, weak appState] in
                    guard let self, let appState else { return false }
                    guard case .connected = appState.tunnelLifecycleOwner.state else { return false }
                    guard let pairing = appState.currentDurablePairing else { return false }
                    guard pairing.instanceID == expectedInstanceID else { return false }
                    guard appState.currentDurablePairingRevision == snapshotRevision else { return false }

                    if self.isPeerSupportingSetup {
                        return self.supportingIdentityAdmitted(expectedInstanceID: expectedInstanceID,
                                                               revision: snapshotRevision)
                    } else {
                        guard appState.isJournalMarkConfirmed,
                              appState.confirmedMark == expectedMark,
                              appState.currentDurablePairingAdmissionIsReady else {
                            return false
                        }
                        return true
                    }
                },
                fetchTunnelIdentity: { [weak self] in
                    await self?.fetchTunnelIdentity(expectedInstanceID: expectedInstanceID) ?? .absent
                },
                fetchDirectIdentity: { await Self.fetchDirectIdentity(expectedInstanceID: expectedInstanceID) },
                openURL: { [weak appState] url in
                    guard let appState else { return false }
                    return appState.openBrowserURLDirectly(url)
                },
                persistFinish: { [weak self] in
                    guard let self else { return false }
                    return self.setPhase(nil)
                }
            )

            if !success {
                self.finalOpenError = UICopy.SETUP_COULDNT_FINISH
            } else {
                self.finalOpenError = nil
            }
        }
    }
}
