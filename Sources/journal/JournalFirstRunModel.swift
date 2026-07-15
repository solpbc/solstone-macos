// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntime
import Observation
import os
import SolstoneCore

enum JournalFirstRunRoute: Equatable {
    case deciding
    case ritual(JournalFirstRunStep)
    case adopting
    case home
}

enum JournalFirstRunStep: Equatable {
    case nameLocation
    case setupProgress
    case markReveal
    case finalizing
}

protocol JournalSetupRunning: Sendable {
    func run(
        journalRoot: URL,
        skipService: Bool,
        progress: @escaping @Sendable (JournalSetupProgressEvent) async -> Void
    ) async throws -> JournalSetupResult
}

extension JournalSetupRunner: JournalSetupRunning {}

protocol JournalInitClienting: Sendable {
    func getMark() async throws -> JournalInitMarkResponse
    func regenerateMark() async throws -> JournalInitMarkResponse
    func lockMark() async throws -> JournalInitMarkResponse
    func finalize(body: JournalInitFinalizeRequest) async throws -> JournalInitFinalizeResponse
    func probeSetupComplete() async throws -> JournalInitSetupProbe
}

extension JournalInitClient: JournalInitClienting {}

@MainActor
@Observable
final class JournalFirstRunModel {
    typealias NameUpdate = @Sendable (String) async throws -> JournalConfig
    typealias SupervisorStart = @MainActor @Sendable (URL) async -> Bool
    typealias MachineNameProvider = @Sendable () -> String

    @ObservationIgnored private let config: JournalAppConfig
    @ObservationIgnored private let setupRunner: any JournalSetupRunning
    @ObservationIgnored private let initClient: any JournalInitClienting
    @ObservationIgnored private let updateName: NameUpdate
    @ObservationIgnored private let startSupervisor: SupervisorStart
    @ObservationIgnored private let handoffStore: any JournalHandoffStoring
    @ObservationIgnored private let journalFileReader: any OnDiskJournalFileReading
    @ObservationIgnored private let discoveryQualificationTimeout: TimeInterval
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private weak var windowModel: JournalWindowModel?

    var route: JournalFirstRunRoute = .deciding
    var draftName: String
    var journalRoot: URL
    var setupEvents: [JournalSetupProgressEvent] = []
    var setupRenderedLog = ""
    var currentStep: String?
    var currentMark: JournalMark?
    var markRenderGeneration = 0
    var markLocked = false
    var isTryingAnotherMark = false
    var isLockingMark = false
    var isFinalizing = false
    var finalizeWarnings: [String] = []
    var nameWriteError: String?
    var adoptMessage: String?
    var errorMessage: String?

    private var hasPostedJournalMarkLocked = false
    private var pendingDiscoveryHandoff: JournalHandoff?

    init(
        config: JournalAppConfig,
        setupRunner: any JournalSetupRunning = JournalSetupRunner(),
        initClient: any JournalInitClienting = JournalInitClient(),
        updateName: @escaping NameUpdate = { try await JournalConfigClient().updateJournalName($0) },
        startSupervisor: @escaping SupervisorStart,
        handoffStore: any JournalHandoffStoring = JournalHandoffStore(),
        machineNameProvider: @escaping MachineNameProvider = {
            let localized = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let localized, !localized.isEmpty { return localized }
            return ProcessInfo.processInfo.hostName
        },
        notificationCenter: NotificationCenter = .default,
        journalFileReader: any OnDiskJournalFileReading = LiveOnDiskJournalFileReader(),
        discoveryQualificationTimeout: TimeInterval = 1.0,
        windowModel: JournalWindowModel? = nil
    ) {
        self.config = config
        self.setupRunner = setupRunner
        self.initClient = initClient
        self.updateName = updateName
        self.startSupervisor = startSupervisor
        self.handoffStore = handoffStore
        self.journalFileReader = journalFileReader
        self.discoveryQualificationTimeout = discoveryQualificationTimeout
        self.notificationCenter = notificationCenter
        self.windowModel = windowModel

        let machineName = machineNameProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        self.draftName = machineName.isEmpty ? "your journal" : machineName
        self.journalRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("journal", isDirectory: true)
    }

    func decideLaunchRoute() async {
        pendingDiscoveryHandoff = nil

        do {
            guard let handoff = try handoffStore.load() else {
                await continueWithoutHandoff()
                return
            }

            switch handoff.provenance {
            case JournalHandoffProvenance.bundledMigration:
                route = .adopting
                await adoptFromHandoff()
            case JournalHandoffProvenance.observerDiscovery:
                await routeDiscoveryHandoff(handoff)
            default:
                consumeHandoffBestEffort()
                beginCreateAtDefaultLocation()
            }
        } catch {
            consumeHandoffBestEffort()
            beginCreateAtDefaultLocation()
        }
    }

    private func continueWithoutHandoff() async {
        guard let root = config.journalRoot else {
            beginCreate()
            return
        }

        await resumeConfiguredRoot(root)
    }

    private func routeDiscoveryHandoff(_ handoff: JournalHandoff) async {
        let root = URL(fileURLWithPath: handoff.journalRootPath, isDirectory: true)
            .standardizedFileURL
        let fileReader = journalFileReader
        let timeout = discoveryQualificationTimeout
        let qualifies: Bool
        do {
            qualifies = try await withTimeout(seconds: timeout) {
                await journalDirectoryQualifies(at: root.path, using: fileReader)
            }
        } catch {
            qualifies = false
        }

        guard qualifies else {
            consumeHandoffBestEffort()
            beginCreateAtDefaultLocation()
            return
        }

        journalRoot = root
        pendingDiscoveryHandoff = handoff
        errorMessage = nil
        adoptMessage = nil
        route = .ritual(.nameLocation)
    }

    private func consumeHandoffBestEffort() {
        try? handoffStore.consume()
    }

    private func beginCreateAtDefaultLocation() {
        errorMessage = nil
        adoptMessage = nil
        journalRoot = defaultJournalRoot
        config.journalRoot = nil
        route = .ritual(.nameLocation)
    }

    private var defaultJournalRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("journal", isDirectory: true)
            .standardizedFileURL
    }

    func beginCreate() {
        errorMessage = nil
        adoptMessage = nil
        if let configuredRoot = config.journalRoot {
            journalRoot = configuredRoot.standardizedFileURL
        } else {
            journalRoot = defaultJournalRoot
        }
        route = .ritual(.nameLocation)
    }

    func continueFromNameLocation() async {
        if pendingDiscoveryHandoff != nil {
            consumeHandoffBestEffort()
            pendingDiscoveryHandoff = nil
        }
        config.journalRoot = journalRoot.standardizedFileURL
        await runSetupThenStartSupervisor()
    }

    func runSetupThenStartSupervisor() async {
        route = .ritual(.setupProgress)
        setupEvents = []
        setupRenderedLog = ""
        currentStep = nil
        errorMessage = nil

        do {
            let result = try await setupRunner.run(
                journalRoot: journalRoot,
                skipService: true,
                progress: { [weak self] event in
                    await MainActor.run {
                        self?.applySetupEvent(event)
                    }
                }
            )
            setupRenderedLog = result.renderedLog
            guard await startSupervisor(journalRoot.standardizedFileURL) else {
                errorMessage = supervisorFailureMessage()
                return
            }
            await routeAfterProbe()
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }

    func regenerateMark() async {
        guard !isTryingAnotherMark else { return }
        isTryingAnotherMark = true
        errorMessage = nil
        do {
            let response = try await initClient.regenerateMark()
            applyMarkResponse(response)
        } catch {
            errorMessage = readableMessage(for: error)
        }
        isTryingAnotherMark = false
    }

    func lockCurrentMark() async {
        guard !isLockingMark else { return }
        isLockingMark = true
        errorMessage = nil
        do {
            let response = try await initClient.lockMark()
            applyMarkResponse(response)
            await finalizeAndLandHome()
        } catch {
            errorMessage = readableMessage(for: error)
        }
        isLockingMark = false
    }

    func finalizeAndLandHome() async {
        guard !isFinalizing else { return }
        route = .ritual(.finalizing)
        isFinalizing = true
        errorMessage = nil

        do {
            switch try await initClient.probeSetupComplete() {
            case .complete:
                isFinalizing = false
                landHome(lockedMark: markLocked ? currentMark : nil)
                return
            case .incomplete:
                break
            }

            let response = try await initClient.finalize(body: JournalInitFinalizeRequest())
            finalizeWarnings = response.warnings
            await writeNameAfterFinalize()
            isFinalizing = false
            landHome(lockedMark: markLocked ? currentMark : nil)
        } catch {
            isFinalizing = false
            errorMessage = readableMessage(for: error)
        }
    }

    func resumeConfiguredRoot(_ root: URL) async {
        journalRoot = root.standardizedFileURL
        config.journalRoot = journalRoot
        errorMessage = nil

        guard await startSupervisor(journalRoot) else {
            await runSetupThenStartSupervisor()
            return
        }

        await routeAfterProbe()
    }

    func adoptFromHandoff() async {
        route = .adopting
        adoptMessage = JournalFirstRunCopy.adoptOpening
        errorMessage = nil

        do {
            guard let handoff = try handoffStore.load() else {
                beginCreate()
                return
            }
            let root = URL(fileURLWithPath: handoff.journalRootPath, isDirectory: true).standardizedFileURL
            journalRoot = root
            draftName = handoff.observerName.trimmingCharacters(in: .whitespacesAndNewlines)
            config.journalRoot = root

            guard await startSupervisor(root) else {
                errorMessage = supervisorFailureMessage()
                return
            }

            try await completeAdoptAfterSuccessfulStart()
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }

    private func completeAdoptAfterSuccessfulStart() async throws {
        switch try await initClient.probeSetupComplete() {
        case .complete:
            try handoffStore.consume()
            adoptMessage = JournalFirstRunCopy.adoptLandingLine
            let response = try? await initClient.getMark()
            if let response, response.locked {
                applyMarkResponse(response)
                landHome(lockedMark: response.mark)
            } else {
                landHome(lockedMark: nil)
            }
        case .incomplete:
            let response = try await initClient.getMark()
            if response.locked {
                try handoffStore.consume()
                applyMarkResponse(response)
                adoptMessage = JournalFirstRunCopy.adoptLandingLine
                await finalizeAndLandHome()
            } else {
                try handoffStore.consume()
                currentMark = nil
                markLocked = false
                adoptMessage = JournalFirstRunCopy.adoptLandingLine
                landHome(lockedMark: nil)
            }
        }
    }

    private func routeAfterProbe() async {
        do {
            switch try await initClient.probeSetupComplete() {
            case .complete:
                let response = try? await initClient.getMark()
                if let response, response.locked {
                    applyMarkResponse(response)
                    landHome(lockedMark: response.mark)
                } else {
                    landHome(lockedMark: nil)
                }
            case .incomplete:
                let response = try await initClient.getMark()
                applyMarkResponse(response)
                if response.locked {
                    await finalizeAndLandHome()
                } else {
                    route = .ritual(.markReveal)
                }
            }
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }

    private func writeNameAfterFinalize() async {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        do {
            let updated = try await updateName(name)
            windowModel?.journalName = updated.journal.name
            windowModel?.draftJournalName = updated.journal.name
            windowModel?.nameError = nil
            nameWriteError = nil
        } catch {
            nameWriteError = JournalFirstRunCopy.nameCanBeSavedLater
            windowModel?.journalName = ""
            windowModel?.draftJournalName = name
            windowModel?.nameError = JournalFirstRunCopy.nameCanBeSavedLater
            if case JournalConfigClientError.serverError(400) = error {
                Logger.journalApp.notice("journal name section unavailable after first-run finalize")
            } else {
                Logger.journalApp.warning("journal name write after first-run finalize failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func landHome(lockedMark: JournalMark?) {
        let validatedMark = lockedMark.flatMap(JournalMark.validate)
        if let validatedMark {
            currentMark = validatedMark
            markLocked = true
            if !hasPostedJournalMarkLocked {
                _ = JournalMarkLockedNotification.post(mark: validatedMark, center: notificationCenter)
                hasPostedJournalMarkLocked = true
            }
        } else {
            currentMark = nil
            markLocked = false
        }

        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        windowModel?.applyFirstRunLanding(
            identityMark: validatedMark,
            draftName: name,
            nameError: nameWriteError
        )
        route = .home
    }

    private func applySetupEvent(_ event: JournalSetupProgressEvent) {
        setupEvents.append(event)
        switch event {
        case .stepStarted(let step, _, _):
            currentStep = step
        case .stepFailed(let step, _, let message):
            currentStep = step
            errorMessage = message
        case .warning, .completed:
            break
        }
    }

    private func applyMarkResponse(_ response: JournalInitMarkResponse) {
        currentMark = response.mark
        markLocked = response.locked
        markRenderGeneration += 1
    }

    private func supervisorFailureMessage() -> String {
        windowModel?.supervisor.blockedReason
            ?? JournalFirstRunCopy.adoptFailed
    }

    private func readableMessage(for error: Error) -> String {
        if let runnerError = error as? JournalSetupRunnerError {
            switch runnerError {
            case .gateBlocked(let blockage):
                return blockage.ownerMessage
            case .materializeFailed(let message),
                 .runtimeDirectoryFailed(let message),
                 .subprocessLaunchFailed(let message),
                 .setupFailed(_, let message):
                return message
            case .timedOut:
                return "setup timed out"
            case .duplicateCompletion:
                return "setup reported completion twice"
            case .missingCompletion:
                return "setup did not finish"
            }
        }
        return error.localizedDescription
    }
}
