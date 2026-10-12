// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
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
    case finishInBrowser
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
    func probeSetupComplete() async throws -> JournalInitSetupProbe
}

extension JournalInitClient: JournalInitClienting {}

@MainActor
@Observable
final class JournalFirstRunModel {
    typealias SupervisorStart = @MainActor @Sendable (URL) async -> Bool
    typealias URLOpener = @MainActor (URL) -> Bool

    static let defaultInitPageURL = URL(string: "http://127.0.0.1:5015/init")!

    @ObservationIgnored private let config: JournalAppConfig
    @ObservationIgnored private let setupRunner: any JournalSetupRunning
    @ObservationIgnored private let initClient: any JournalInitClienting
    @ObservationIgnored private let startSupervisor: SupervisorStart
    @ObservationIgnored private let handoffStore: any JournalHandoffStoring
    @ObservationIgnored private let journalFileReader: any OnDiskJournalFileReading
    @ObservationIgnored private let discoveryQualificationTimeout: TimeInterval
    @ObservationIgnored private let initPageURL: URL
    @ObservationIgnored private let openURL: URLOpener
    @ObservationIgnored private let browserPollInterval: Duration
    @ObservationIgnored private weak var windowModel: JournalWindowModel?

    var route: JournalFirstRunRoute = .deciding
    var journalRoot: URL
    var setupEvents: [JournalSetupProgressEvent] = []
    var setupRenderedLog = ""
    var currentStep: String?
    var adoptMessage: String?
    var errorMessage: String?

    @ObservationIgnored private var setupTask: Task<JournalSetupResult, Error>?
    @ObservationIgnored private var browserWaitTask: Task<Void, Never>?
    @ObservationIgnored private var browserWaitGeneration = 0
    private var isTerminating = false

    private var pendingDiscoveryHandoff: JournalHandoff?

    init(
        config: JournalAppConfig,
        setupRunner: any JournalSetupRunning = JournalSetupRunner(materializer: NativeJournalRuntimeMaterializer()),
        initClient: any JournalInitClienting = JournalInitClient(),
        startSupervisor: @escaping SupervisorStart,
        handoffStore: any JournalHandoffStoring = JournalHandoffStore(),
        journalFileReader: any OnDiskJournalFileReading = LiveOnDiskJournalFileReader(),
        discoveryQualificationTimeout: TimeInterval = 1.0,
        initPageURL: URL = JournalFirstRunModel.defaultInitPageURL,
        openURL: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        browserPollInterval: Duration = .seconds(2),
        windowModel: JournalWindowModel? = nil
    ) {
        self.config = config
        self.setupRunner = setupRunner
        self.initClient = initClient
        self.startSupervisor = startSupervisor
        self.handoffStore = handoffStore
        self.journalFileReader = journalFileReader
        self.discoveryQualificationTimeout = discoveryQualificationTimeout
        self.initPageURL = initPageURL
        self.openURL = openURL
        self.browserPollInterval = browserPollInterval
        self.windowModel = windowModel

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
        errorMessage = nil

        do {
            try await runSetup(at: journalRoot)
            guard await startSupervisor(journalRoot.standardizedFileURL) else {
                errorMessage = supervisorFailureMessage()
                return
            }
            await routeAfterProbe()
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }

    func prepareForTermination() async {
        isTerminating = true
        browserWaitTask?.cancel()
        browserWaitTask = nil
        let task = setupTask
        task?.cancel()
        _ = try? await task?.value
    }

    func resetAfterFailedUpdaterInstall() {
        isTerminating = false
        if route == .ritual(.finishInBrowser) {
            startBrowserWaitIfNeeded()
        }
    }

    private func runSetup(at journalRoot: URL) async throws {
        guard !isTerminating, setupTask == nil else { throw CancellationError() }
        setupEvents = []
        setupRenderedLog = ""
        currentStep = nil

        let task = Task { [setupRunner, weak self] in
            try await setupRunner.run(
                journalRoot: journalRoot,
                skipService: true,
                progress: { [weak self] event in
                    await MainActor.run { self?.applySetupEvent(event) }
                }
            )
        }
        setupTask = task
        defer { setupTask = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard !isTerminating, !task.isCancelled else { throw CancellationError() }
        setupRenderedLog = result.renderedLog
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
            config.journalRoot = root

            try await runSetup(at: root)
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
        let probe = try await initClient.probeSetupComplete()
        try handoffStore.consume()
        adoptMessage = JournalFirstRunCopy.adoptLandingLine
        switch probe {
        case .complete:
            await landHome()
        case .incomplete:
            await finishInBrowser()
        }
    }

    private func routeAfterProbe() async {
        let probe: JournalInitSetupProbe
        do {
            probe = try await initClient.probeSetupComplete()
        } catch {
            errorMessage = readableMessage(for: error)
            return
        }
        switch probe {
        case .complete:
            await landHome()
        case .incomplete:
            await finishInBrowser()
        }
    }

    /// The journal's own first-run page finishes creating the journal: it asks for the mark and
    /// the owner's choices, then records the first run as done. This app only opens it in the
    /// owner's browser and waits for the journal to report it done.
    private func finishInBrowser() async {
        errorMessage = nil
        route = .ritual(.finishInBrowser)
        openInitPage()
        await startBrowserWaitIfNeeded().value
    }

    /// Opens the page again, for an owner who closed it before finishing.
    func reopenInBrowser() {
        openInitPage()
        startBrowserWaitIfNeeded()
    }

    private func openInitPage() {
        if !openURL(initPageURL) {
            Logger.journalApp.error("failed to open \(self.initPageURL.absoluteString, privacy: .public) in the browser")
        }
    }

    @discardableResult
    private func startBrowserWaitIfNeeded() -> Task<Void, Never> {
        if let browserWaitTask {
            return browserWaitTask
        }
        browserWaitGeneration += 1
        let generation = browserWaitGeneration
        let task = Task { @MainActor [weak self] in
            await self?.waitForSetupComplete()
            if self?.browserWaitGeneration == generation {
                self?.browserWaitTask = nil
            }
        }
        browserWaitTask = task
        return task
    }

    private func waitForSetupComplete() async {
        while !Task.isCancelled, !isTerminating {
            do {
                if try await initClient.probeSetupComplete() == .complete {
                    guard !Task.isCancelled, !isTerminating else { return }
                    await landHome()
                    return
                }
            } catch {
                Logger.journalApp.debug("first-run probe while waiting on the browser: \(String(describing: error), privacy: .public)")
            }
            do {
                try await Task.sleep(for: browserPollInterval)
            } catch {
                return
            }
        }
    }

    private func landHome() async {
        windowModel?.applyFirstRunLanding()
        route = .home
        await windowModel?.fetchIdentityIfNeeded()
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
