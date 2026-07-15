// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import JournalMarkKit
import Observation
import os
import SolstoneCore

enum AcquirePhase: Equatable, Sendable {
    case fetchingAppcast
    case selectingLatestSparkleVersion
    case validatingLength
    case downloadingDMG
    case verifyingEdDSA
    case mountingDMG
    case verifyingJournalAppTrust
    case installingToApplications
    case clearingQuarantine
    case cleaningTemporaryFiles
}

enum JournalHandoffStep: Equatable, Sendable {
    case idle
    case acquiring(AcquirePhase)
    case checkingRunningJournal
    case writingHandoff
    case launchingJournal
    case waitingForAdoption
    case authGate
    case flippingToExternal
    case triggeringSyncDrain
    case confirmingMarkBestEffort
    case completed
    case failed(JournalHandoffFailure)
    case aborted(JournalHandoffFailure)
}

extension JournalHandoffStep {
    var ownerStatusMessage: String {
        switch self {
        case .idle:
            return "ready to move your journal into its own app"
        case .acquiring(.fetchingAppcast),
             .acquiring(.selectingLatestSparkleVersion),
             .acquiring(.validatingLength):
            return "checking for the journal app"
        case .acquiring(.downloadingDMG):
            return "getting the journal app"
        case .acquiring(.verifyingEdDSA),
             .acquiring(.mountingDMG),
             .acquiring(.verifyingJournalAppTrust):
            return "checking the journal app"
        case .acquiring(.installingToApplications),
             .acquiring(.clearingQuarantine),
             .acquiring(.cleaningTemporaryFiles):
            return "installing the journal app"
        case .checkingRunningJournal:
            return "getting journal ready"
        case .writingHandoff:
            return "preparing your journal"
        case .launchingJournal:
            return "opening journal"
        case .waitingForAdoption:
            return "waiting for journal to finish setup"
        case .authGate:
            return "checking the saved journal key"
        case .flippingToExternal:
            return "linking sol to the journal app"
        case .triggeringSyncDrain:
            return "sending kept segments to your journal"
        case .confirmingMarkBestEffort:
            return "checking your journal mark"
        case .completed:
            return "your journal app is ready"
        case .failed(let failure), .aborted(let failure):
            return failure.ownerMessage
        }
    }

    var axState: JournalHandoffAXState {
        switch self {
        case .idle:
            return .idle
        case .acquiring:
            return .acquiring
        case .checkingRunningJournal:
            return .checkingRunningJournal
        case .writingHandoff:
            return .writingHandoff
        case .launchingJournal:
            return .launchingJournal
        case .waitingForAdoption:
            return .waitingForAdoption
        case .authGate:
            return .authGate
        case .flippingToExternal:
            return .flippingToExternal
        case .triggeringSyncDrain:
            return .triggeringSyncDrain
        case .confirmingMarkBestEffort:
            return .confirmingMarkBestEffort
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .aborted:
            return .aborted
        }
    }
}

enum JournalHandoffFailure: Error, Equatable, Sendable {
    case missingJournalPath
    case journalPathMissing(String)
    case applicationsDirectoryUnavailable
    case applicationsDirectoryUnwritable
    case feedNotYetPublished
    case appcastUnavailable(String)
    case invalidAppcast(String)
    case missingLength
    case nonIntegerLength(String)
    case lengthExceedsCap(length: Int64, cap: Int64)
    case lengthMismatch(expected: Int64, actual: Int64)
    case invalidSignature
    case signatureVerificationFailed
    case mountFailed(String)
    case trustFailed(String)
    case installFailed(String)
    case runningJournalWouldNotQuit
    case launchFailed(String)
    case adoptionTimedOut
    case initProbeFailed(String)
    case authenticationFailed(String)
    case writeHandoffFailed(String)
    case cancelled

    var isAbort: Bool {
        switch self {
        case .missingJournalPath,
             .journalPathMissing,
             .runningJournalWouldNotQuit,
             .authenticationFailed,
             .cancelled:
            return true
        default:
            return false
        }
    }

    var ownerMessage: String {
        switch self {
        case .applicationsDirectoryUnavailable:
            return "couldn't find /Applications. sol did not change your journal link."
        case .applicationsDirectoryUnwritable:
            return "couldn't install the journal app in /Applications. open sol from an administrator account and try again."
        case .feedNotYetPublished:
            return "the journal app isn't available yet — sol is keeping everything safe on this mac"
        case .runningJournalWouldNotQuit:
            return "journal is still open. quit journal and try again."
        case .missingJournalPath, .journalPathMissing:
            return "sol couldn't find your journal folder. open settings and choose your journal again."
        case .authenticationFailed:
            return "this journal didn't accept sol's saved key. sol did not change your link."
        case .adoptionTimedOut:
            return "journal didn't finish setup in time. sol did not change your journal link."
        case .cancelled:
            return "journal handoff stopped. sol did not change your journal link."
        case .appcastUnavailable,
             .invalidAppcast,
             .missingLength,
             .nonIntegerLength,
             .lengthExceedsCap,
             .lengthMismatch,
             .invalidSignature,
             .signatureVerificationFailed,
             .mountFailed,
             .trustFailed,
             .installFailed,
             .launchFailed,
             .initProbeFailed,
             .writeHandoffFailed:
            return "journal handoff couldn't finish. sol did not change your journal link."
        }
    }
}

struct JournalHandoffResumeProbes: Equatable, Sendable {
    var serviceMode: ServiceMode?
    var journalPath: String?
    var installedTrusted: Bool
    var running: Bool
    var handoffFileExists: Bool
    var setupComplete: Bool
    var storedKeyAuthValid: Bool?

    init(
        serviceMode: ServiceMode?,
        journalPath: String?,
        installedTrusted: Bool,
        running: Bool,
        handoffFileExists: Bool,
        setupComplete: Bool,
        storedKeyAuthValid: Bool? = nil
    ) {
        self.serviceMode = serviceMode
        self.journalPath = journalPath
        self.installedTrusted = installedTrusted
        self.running = running
        self.handoffFileExists = handoffFileExists
        self.setupComplete = setupComplete
        self.storedKeyAuthValid = storedKeyAuthValid
    }
}

func deriveResumeState(probes: JournalHandoffResumeProbes) -> JournalHandoffStep {
    if probes.serviceMode == .external {
        return .completed
    }

    guard let journalPath = probes.journalPath?.trimmingCharacters(in: .whitespacesAndNewlines),
          !journalPath.isEmpty
    else {
        return .aborted(.missingJournalPath)
    }
    _ = journalPath

    guard probes.installedTrusted else {
        return .acquiring(.fetchingAppcast)
    }

    if probes.setupComplete {
        return .authGate
    }

    if !probes.handoffFileExists && probes.running {
        return .authGate
    }

    if probes.handoffFileExists {
        return probes.running ? .waitingForAdoption : .launchingJournal
    }

    _ = probes.storedKeyAuthValid
    return .writingHandoff
}

@MainActor
protocol AppcastClient {
    func fetchAppcast(from url: URL) async throws -> Data
}

@MainActor
protocol DMGDownloader {
    func downloadDMG(from url: URL, expectedLength: Int64, maxBytes: Int64) async throws -> URL
}

@MainActor
protocol DiskImageMounter {
    func mount(dmgURL: URL) async throws -> MountedDiskImage
    func detach(_ image: MountedDiskImage) async
}

@MainActor
protocol TrustVerifier {
    func verifyJournalApp(at url: URL) async throws
}

@MainActor
protocol InitProbe {
    func probeSetupComplete() async throws -> JournalInitSetupProbe
}

@MainActor
protocol ConnectionTester {
    func testConnection(serverURL: String, serverKey: String) async -> String?
}

@MainActor
protocol RunningJournalController: AnyObject {
    func installedURL() -> URL?
    func runningPID() -> pid_t?
    func terminateRunningJournal() -> Bool
    func launchJournal(at url: URL) throws
    func launchJournalActivating(at url: URL) throws
}

@MainActor
protocol ConfigFlipper: AnyObject {
    func flipToExternal(appState: AppState)
    func triggerSync(appState: AppState)
}

struct MountedDiskImage: Equatable, Sendable {
    let mountPoint: URL
    let journalAppURL: URL
}

struct AppcastItem: Equatable, Sendable {
    let version: Int
    let shortVersionString: String?
    let url: URL
    let length: Int64
    let mimeType: String
    let edSignature: String
}

struct JournalHandoffDependencies {
    var appcastClient: any AppcastClient
    var appcastFeedResolver: @MainActor @Sendable () -> JournalHandoffFeedSelection
    var downloader: any DMGDownloader
    var mounter: any DiskImageMounter
    var trustVerifier: any TrustVerifier
    var initProbe: any InitProbe
    var connectionTester: any ConnectionTester
    var runningJournal: any RunningJournalController
    var configFlipper: any ConfigFlipper
    var handoffFileURL: URL
    var applicationsURL: URL
    var publicEDKeyBase64: String
    var maxDMGBytes: Int64
    var adoptionTimeout: Duration
    var adoptionPollInterval: Duration
    var runningTerminationTimeout: Duration
    var runningTerminationPollInterval: Duration
    var fileManager: FileManager
    var now: @Sendable () -> Date

    @MainActor
    static func live(defaults: UserDefaults = .standard) -> JournalHandoffDependencies {
        JournalHandoffDependencies(
            appcastClient: LiveAppcastClient(),
            appcastFeedResolver: { JournalHandoffFeed.resolve(defaults: defaults) },
            downloader: LiveDMGDownloader(),
            mounter: LiveDiskImageMounter(),
            trustVerifier: LiveTrustVerifier(),
            initProbe: LiveInitProbe(),
            connectionTester: LiveConnectionTester(),
            runningJournal: LiveRunningJournalController(),
            configFlipper: LiveConfigFlipper(),
            handoffFileURL: JournalHandoffFile.url(),
            applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true),
            publicEDKeyBase64: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
                ?? JournalHandoffConstants.productionPublicEDKeyBase64,
            maxDMGBytes: JournalHandoffConstants.maxDMGBytes,
            adoptionTimeout: .seconds(900),
            adoptionPollInterval: .seconds(1),
            runningTerminationTimeout: .seconds(15),
            runningTerminationPollInterval: .milliseconds(250),
            fileManager: .default,
            now: Date.init
        )
    }

    @MainActor
    func makeAcquirer() -> JournalAppAcquirer {
        JournalAppAcquirer(
            appcastFeedResolver: appcastFeedResolver,
            appcastClient: appcastClient,
            downloader: downloader,
            mounter: mounter,
            trustVerifier: trustVerifier,
            publicEDKeyBase64: publicEDKeyBase64,
            maxDMGBytes: maxDMGBytes,
            applicationsURL: applicationsURL,
            fileManager: fileManager
        )
    }
}

enum JournalHandoffConstants {
    static let journalBundleIdentifier = "app.solstone.journal"
    static let teamIdentifier = "7QCG8V4M6H"
    static let appcastURL = URL(string: "https://updates.solstone.app/journal-macos/appcast.xml")!
    static let stagingAppcastURLString = "https://updates.solstone.app/journal-macos/_staging/appcast.xml"
    static let stagingAppcastURL = URL(string: stagingAppcastURLString)!
    static let handoffFeedOverrideDefaultsKey = "solstone.journal.handoffFeedOverride"
    static let productionPublicEDKeyBase64 = "5EP/CLtfMrN2qC8zWsHeIWcPVPjqFH7hW4m8cGX7Qg0="
    static let provenance = JournalHandoffProvenance.bundledMigration
    static let discoveryCapableJournalBuild = 9
    static let maxDMGBytes: Int64 = 1_073_741_824
}

enum JournalHandoffFeed: Equatable, Sendable {
    case production
    case staging
    case rejectedOverride

    var logDescription: String {
        switch self {
        case .production:
            "production"
        case .staging:
            "staging"
        case .rejectedOverride:
            "rejected override; production"
        }
    }

    static func resolve(defaults: UserDefaults) -> JournalHandoffFeedSelection {
        guard let rawOverride = defaults.object(forKey: JournalHandoffConstants.handoffFeedOverrideDefaultsKey) else {
            return JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production)
        }

        guard let override = rawOverride as? String else {
            return JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .rejectedOverride)
        }

        let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOverride == JournalHandoffConstants.stagingAppcastURLString {
            return JournalHandoffFeedSelection(url: JournalHandoffConstants.stagingAppcastURL, feed: .staging)
        }

        return JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .rejectedOverride)
    }
}

struct JournalHandoffFeedSelection: Equatable, Sendable {
    let url: URL
    let feed: JournalHandoffFeed
}

@MainActor
@Observable
final class JournalHandoffOrchestrator {
    private(set) var step: JournalHandoffStep = .idle {
        didSet {
            guard oldValue != step else { return }
            onStepTransition?(step)
        }
    }

    @ObservationIgnored
    private var task: Task<Void, Never>?
    @ObservationIgnored
    var onStepTransition: (@MainActor (JournalHandoffStep) -> Void)?
    @ObservationIgnored
    private let dependencies: JournalHandoffDependencies

    init(dependencies: JournalHandoffDependencies = .live()) {
        self.dependencies = dependencies
    }

    func start(
        appState: AppState,
        markDriver: JournalMarkConfirmationDriver,
        markFetch: @escaping JournalMarkConfirmationDriver.MarkFetcher
    ) {
        guard task == nil else { return }

        task = Task { @MainActor [weak self, weak appState, weak markDriver] in
            guard let self, let appState, let markDriver else { return }
            defer {
                self.task = nil
            }
            await self.run(appState: appState, markDriver: markDriver, markFetch: markFetch)
        }
    }

    @discardableResult
    func run(
        appState: AppState,
        markDriver: JournalMarkConfirmationDriver,
        markFetch: @escaping JournalMarkConfirmationDriver.MarkFetcher
    ) async -> JournalHandoffStep {
        appState.journalHandoffActive = true
        defer { appState.journalHandoffActive = false }

        let resumeStep = await deriveResumeStep(appState: appState)
        step = resumeStep

        if isTerminal(resumeStep) {
            return resumeStep
        }

        do {
            try Task.checkCancellation()

            let trustedAppURL: URL
            switch resumeStep {
            case .acquiring:
                trustedAppURL = try await acquireJournalApp()
            default:
                trustedAppURL = try await installedTrustedJournalURL()
            }

            try await ensureJournalReadyForHandoff(startingFrom: resumeStep, trustedAppURL: trustedAppURL)
            try await writeHandoffIfNeeded(appState: appState)
            try await launchAndWaitForAdoptionIfNeeded(startingFrom: resumeStep, trustedAppURL: trustedAppURL)
            try await performAuthGate(appState: appState)

            step = .flippingToExternal
            dependencies.configFlipper.flipToExternal(appState: appState)

            step = .triggeringSyncDrain
            Logger.upload.info("journal handoff: triggering sync drain after external flip")
            dependencies.configFlipper.triggerSync(appState: appState)

            step = .confirmingMarkBestEffort
            startBestEffortMarkConfirm(
                appState: appState,
                markDriver: markDriver,
                markFetch: markFetch
            )

            step = .completed
            Logger.setup.info("journal handoff completed")
            return .completed
        } catch is CancellationError {
            return finish(.cancelled)
        } catch let failure as JournalHandoffFailure {
            return finish(failure)
        } catch {
            return finish(.appcastUnavailable(String(describing: error)))
        }
    }

    func deriveResumeStep(appState: AppState) async -> JournalHandoffStep {
        let installedTrusted: Bool
        if let installed = dependencies.runningJournal.installedURL() {
            installedTrusted = (try? await dependencies.trustVerifier.verifyJournalApp(at: installed)) != nil
        } else {
            installedTrusted = false
        }

        let setupComplete = (try? await dependencies.initProbe.probeSetupComplete()) == .complete
        let running = dependencies.runningJournal.runningPID() != nil
        let handoffExists = dependencies.fileManager.fileExists(atPath: dependencies.handoffFileURL.path)
        let authValid: Bool?
        if let serverURL = appState.config.serverURL,
           let serverKey = appState.config.serverKey {
            authValid = await dependencies.connectionTester.testConnection(serverURL: serverURL, serverKey: serverKey) == nil
        } else {
            authValid = nil
        }

        return solstone.deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: appState.config.serviceMode,
            journalPath: appState.config.journalPath,
            installedTrusted: installedTrusted,
            running: running,
            handoffFileExists: handoffExists,
            setupComplete: setupComplete,
            storedKeyAuthValid: authValid
        ))
    }

    private func acquireJournalApp() async throws -> URL {
        try await dependencies.makeAcquirer().acquire { phase in
            self.step = .acquiring(phase)
        }
    }

    private func ensureJournalReadyForHandoff(startingFrom resumeStep: JournalHandoffStep, trustedAppURL: URL) async throws {
        if case .authGate = resumeStep {
            return
        }
        if case .launchingJournal = resumeStep {
            return
        }
        if case .waitingForAdoption = resumeStep {
            return
        }

        step = .checkingRunningJournal
        guard dependencies.runningJournal.runningPID() != nil else {
            return
        }

        Logger.setup.info("journal handoff: asking running journal to quit before handoff")
        _ = dependencies.runningJournal.terminateRunningJournal()
        let deadline = ContinuousClock.now.advanced(by: dependencies.runningTerminationTimeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if dependencies.runningJournal.runningPID() == nil {
                return
            }
            try await Task.sleep(for: dependencies.runningTerminationPollInterval)
        }

        Logger.setup.error("journal handoff: running journal did not quit before timeout")
        throw JournalHandoffFailure.runningJournalWouldNotQuit
    }

    private func writeHandoffIfNeeded(appState: AppState) async throws {
        if step == .authGate || step == .waitingForAdoption || step == .launchingJournal {
            return
        }
        if dependencies.fileManager.fileExists(atPath: dependencies.handoffFileURL.path) {
            let existingData = try? Data(contentsOf: dependencies.handoffFileURL)
            let existingHandoff = existingData.flatMap {
                try? JSONDecoder().decode(JournalHandoff.self, from: $0)
            }
            if existingHandoff?.provenance == JournalHandoffProvenance.bundledMigration {
                return
            }
        }

        step = .writingHandoff
        guard let journalPath = appState.config.journalPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !journalPath.isEmpty
        else {
            throw JournalHandoffFailure.missingJournalPath
        }

        var isDirectory: ObjCBool = false
        guard dependencies.fileManager.fileExists(atPath: journalPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw JournalHandoffFailure.journalPathMissing(journalPath)
        }

        let observerName = appState.config.observerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let handoff = JournalHandoff(
            journalRootPath: journalPath,
            observerName: observerName?.isEmpty == false ? observerName! : ProcessInfo.processInfo.hostName,
            provenance: JournalHandoffConstants.provenance,
            timestamp: dependencies.now()
        )

        do {
            try dependencies.fileManager.createDirectory(
                at: dependencies.handoffFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(handoff)
            try data.write(to: dependencies.handoffFileURL, options: .atomic)
            Logger.setup.info("journal handoff: wrote handoff file")
        } catch {
            throw JournalHandoffFailure.writeHandoffFailed(String(describing: error))
        }
    }

    private func launchAndWaitForAdoptionIfNeeded(startingFrom resumeStep: JournalHandoffStep, trustedAppURL: URL) async throws {
        if case .authGate = resumeStep {
            step = .authGate
            return
        }

        if dependencies.runningJournal.runningPID() == nil {
            step = .launchingJournal
            do {
                try dependencies.runningJournal.launchJournal(at: trustedAppURL)
            } catch {
                throw JournalHandoffFailure.launchFailed(String(describing: error))
            }
        }

        step = .waitingForAdoption
        Logger.setup.info("journal handoff: waiting for journal adoption")
        let deadline = ContinuousClock.now.advanced(by: dependencies.adoptionTimeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            do {
                if try await dependencies.initProbe.probeSetupComplete() == .complete {
                    step = .authGate
                    return
                }
            } catch JournalInitClientError.serverError(401) {
                throw JournalHandoffFailure.authenticationFailed("Invalid API key")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The journal child is not accepting yet (still materializing or
                // starting) — connection errors and odd statuses here are normal
                // transients of the adoption window, not failures. The deadline
                // bounds the wait; only a definitive 401 is terminal above.
                Logger.setup.info("journal handoff: adoption probe not ready yet: \(String(describing: error))")
            }

            if !dependencies.fileManager.fileExists(atPath: dependencies.handoffFileURL.path) {
                step = .authGate
                return
            }

            try await Task.sleep(for: dependencies.adoptionPollInterval)
        }

        Logger.setup.error("journal handoff: adoption wait timed out")
        throw JournalHandoffFailure.adoptionTimedOut
    }

    private func performAuthGate(appState: AppState) async throws {
        step = .authGate
        guard let serverURL = appState.config.serverURL,
              let serverKey = appState.config.serverKey
        else {
            throw JournalHandoffFailure.authenticationFailed("not configured")
        }

        Logger.upload.info("journal handoff: checking stored journal key before external flip")
        if let failure = await dependencies.connectionTester.testConnection(serverURL: serverURL, serverKey: serverKey) {
            Logger.upload.error("journal handoff: auth gate failed: \(failure, privacy: .public)")
            throw JournalHandoffFailure.authenticationFailed(failure)
        }
    }

    private func installedTrustedJournalURL() async throws -> URL {
        guard let installed = dependencies.runningJournal.installedURL() else {
            throw JournalHandoffFailure.trustFailed("journal app is not installed")
        }
        try await dependencies.trustVerifier.verifyJournalApp(at: installed)
        return installed
    }

    private func finish(_ failure: JournalHandoffFailure) -> JournalHandoffStep {
        let terminal: JournalHandoffStep = failure.isAbort ? .aborted(failure) : .failed(failure)
        step = terminal
        if failure.isAbort {
            Logger.setup.error("journal handoff aborted: \(failure.ownerMessage, privacy: .public)")
        } else {
            Logger.setup.error("journal handoff failed: \(failure.ownerMessage, privacy: .public)")
        }
        return terminal
    }

    private func isTerminal(_ step: JournalHandoffStep) -> Bool {
        switch step {
        case .completed, .failed, .aborted:
            return true
        default:
            return false
        }
    }

    private func startBestEffortMarkConfirm(
        appState: AppState,
        markDriver: JournalMarkConfirmationDriver,
        markFetch: @escaping JournalMarkConfirmationDriver.MarkFetcher
    ) {
        guard let serverKey = appState.config.serverKey else { return }
        markDriver.startIfNeeded(
            for: "journal-handoff:\(serverKey)",
            resolveHomeBase: { .url(ServiceMode.bundledServiceURL) },
            fetchMark: markFetch,
            logFallback: { reason in
                Logger.journalMark.info("journal-mark fallback: proceeding without confirmed mark reason=\(reason.rawValue, privacy: .public)")
            }
        )
    }
}

enum JournalAppcastParser {
    static func latestItem(from data: Data) throws -> AppcastItem {
        let parser = XMLParser(data: data)
        let delegate = AppcastXMLDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        guard parser.parse() else {
            throw JournalHandoffFailure.invalidAppcast(parser.parserError?.localizedDescription ?? "parse failed")
        }
        if let firstError = delegate.firstError {
            throw firstError
        }

        let latestByVersion = Dictionary(delegate.items.map { ($0.version, $0) }) { _, replacement in
            replacement
        }
        guard let item = latestByVersion.values.max(by: { $0.version < $1.version }) else {
            throw JournalHandoffFailure.invalidAppcast("missing appcast item")
        }
        return item
    }
}

private final class AppcastXMLDelegate: NSObject, XMLParserDelegate {
    private struct PartialItem {
        var version: Int?
        var shortVersionString: String?
        var enclosureURL: URL?
        var enclosureLength: Int64?
        var enclosureLengthRaw: String?
        var enclosureType: String?
        var edSignature: String?
    }

    private var currentItem: PartialItem?
    private var currentElement: String?
    private var text = ""
    private(set) var items: [AppcastItem] = []
    private(set) var firstError: JournalHandoffFailure?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        switch name {
        case "item":
            currentItem = PartialItem()
        case "sparkle:version", "version":
            currentElement = "version"
            text = ""
        case "sparkle:shortVersionString", "shortVersionString":
            currentElement = "shortVersionString"
            text = ""
        case "enclosure":
            guard currentItem != nil else { return }
            currentItem?.enclosureURL = attributeDict["url"].flatMap(URL.init(string:))
            currentItem?.enclosureType = attributeDict["type"]
            let length = attributeDict["length"]
            currentItem?.enclosureLengthRaw = length
            if let length {
                currentItem?.enclosureLength = Int64(length)
            }
            currentItem?.edSignature = attributeDict.first { key, _ in
                key == "sparkle:edSignature" || key.hasSuffix(":edSignature") || key == "edSignature"
            }?.value
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        switch name {
        case "sparkle:version", "version":
            currentItem?.version = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            currentElement = nil
        case "sparkle:shortVersionString", "shortVersionString":
            currentItem?.shortVersionString = text.trimmingCharacters(in: .whitespacesAndNewlines)
            currentElement = nil
        case "item":
            do {
                let item = try complete(currentItem)
                items.append(item)
            } catch let failure as JournalHandoffFailure {
                firstError = firstError ?? failure
            } catch {
                firstError = firstError ?? .invalidAppcast(String(describing: error))
            }
            currentItem = nil
            currentElement = nil
        default:
            break
        }
    }

    private func complete(_ partial: PartialItem?) throws -> AppcastItem {
        guard let partial else {
            throw JournalHandoffFailure.invalidAppcast("missing item")
        }
        guard let version = partial.version else {
            throw JournalHandoffFailure.invalidAppcast("missing version")
        }
        guard let url = partial.enclosureURL else {
            throw JournalHandoffFailure.invalidAppcast("missing enclosure url")
        }
        guard let rawLength = partial.enclosureLengthRaw else {
            throw JournalHandoffFailure.missingLength
        }
        guard let length = partial.enclosureLength else {
            throw JournalHandoffFailure.nonIntegerLength(rawLength)
        }
        guard let type = partial.enclosureType,
              type == "application/x-apple-diskimage"
        else {
            throw JournalHandoffFailure.invalidAppcast("invalid enclosure type")
        }
        guard let edSignature = partial.edSignature,
              !edSignature.isEmpty
        else {
            throw JournalHandoffFailure.invalidSignature
        }
        return AppcastItem(
            version: version,
            shortVersionString: partial.shortVersionString,
            url: url,
            length: length,
            mimeType: type,
            edSignature: edSignature
        )
    }
}

struct LiveAppcastClient: AppcastClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchAppcast(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw JournalHandoffFailure.appcastUnavailable("invalid response")
        }
        if http.statusCode == 404 {
            throw JournalHandoffFailure.feedNotYetPublished
        }
        guard (200...299).contains(http.statusCode) else {
            throw JournalHandoffFailure.appcastUnavailable("http \(http.statusCode)")
        }
        return data
    }
}

struct LiveDMGDownloader: DMGDownloader {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func downloadDMG(from url: URL, expectedLength: Int64, maxBytes: Int64) async throws -> URL {
        guard expectedLength <= maxBytes else {
            throw JournalHandoffFailure.lengthExceedsCap(length: expectedLength, cap: maxBytes)
        }

        let (temporaryURL, response) = try await session.download(from: url)
        var temporaryURLIsOwned = true
        defer {
            if temporaryURLIsOwned {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw JournalHandoffFailure.appcastUnavailable("invalid download response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw JournalHandoffFailure.appcastUnavailable("download http \(http.statusCode)")
        }

        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("journal-handoff-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("dmg")
        try fileManager.moveItem(at: temporaryURL, to: destination)
        temporaryURLIsOwned = false
        return destination
    }
}

struct LiveDiskImageMounter: DiskImageMounter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func mount(dmgURL: URL) async throws -> MountedDiskImage {
        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("journal-handoff-mount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            try await JournalHandoffProcessRunner.run(
                executable: "/usr/bin/hdiutil",
                arguments: ["attach", dmgURL.path, "-mountpoint", mountPoint.path, "-nobrowse", "-quiet"]
            ).throwIfFailed("hdiutil attach")
            return MountedDiskImage(
                mountPoint: mountPoint,
                journalAppURL: mountPoint.appendingPathComponent("journal.app", isDirectory: true)
            )
        } catch {
            _ = try? await JournalHandoffProcessRunner.run(
                executable: "/usr/bin/hdiutil",
                arguments: ["detach", mountPoint.path, "-quiet", "-force"]
            )
            try? fileManager.removeItem(at: mountPoint)
            throw JournalHandoffFailure.mountFailed(String(describing: error))
        }
    }

    func detach(_ image: MountedDiskImage) async {
        _ = try? await JournalHandoffProcessRunner.run(
            executable: "/usr/bin/hdiutil",
            arguments: ["detach", image.mountPoint.path, "-quiet", "-force"]
        )
        try? fileManager.removeItem(at: image.mountPoint)
    }
}

struct LiveTrustVerifier: TrustVerifier {
    func verifyJournalApp(at url: URL) async throws {
        do {
            try await JournalHandoffProcessRunner.run(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "--deep", "--verbose=2", url.path]
            ).throwIfFailed("codesign verify")
            let details = try await JournalHandoffProcessRunner.run(
                executable: "/usr/bin/codesign",
                arguments: ["-dvvv", url.path]
            )
            guard details.terminationStatus == 0 else {
                throw JournalHandoffFailure.trustFailed(details.combinedOutput)
            }
            guard details.combinedOutput.contains("Identifier=\(JournalHandoffConstants.journalBundleIdentifier)") else {
                throw JournalHandoffFailure.trustFailed("bundle identifier mismatch")
            }
            guard details.combinedOutput.contains("TeamIdentifier=\(JournalHandoffConstants.teamIdentifier)") else {
                throw JournalHandoffFailure.trustFailed("team identifier mismatch")
            }
        } catch let failure as JournalHandoffFailure {
            throw failure
        } catch {
            throw JournalHandoffFailure.trustFailed(String(describing: error))
        }
    }
}

struct LiveInitProbe: InitProbe {
    private let client: JournalInitClient

    init(client: JournalInitClient = JournalInitClient()) {
        self.client = client
    }

    func probeSetupComplete() async throws -> JournalInitSetupProbe {
        try await client.probeSetupComplete()
    }
}

struct LiveConnectionTester: ConnectionTester {
    func testConnection(serverURL: String, serverKey: String) async -> String? {
        await UploadCoordinator.testConnection(serverURL: serverURL, serverKey: serverKey)
    }
}

@MainActor
final class LiveRunningJournalController: RunningJournalController {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func installedURL() -> URL? {
        workspace.urlForApplication(withBundleIdentifier: JournalHandoffConstants.journalBundleIdentifier)
    }

    func runningPID() -> pid_t? {
        workspace.runningApplications.first {
            $0.bundleIdentifier == JournalHandoffConstants.journalBundleIdentifier && !$0.isTerminated
        }?.processIdentifier
    }

    func terminateRunningJournal() -> Bool {
        guard let app = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == JournalHandoffConstants.journalBundleIdentifier && !$0.isTerminated
        }) else {
            return true
        }
        return app.terminate()
    }

    func launchJournal(at url: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        workspace.openApplication(at: url, configuration: configuration)
    }

    func launchJournalActivating(at url: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration)
    }
}

@MainActor
final class LiveConfigFlipper: ConfigFlipper {
    func flipToExternal(appState: AppState) {
        var config = appState.config
        config.serviceMode = .external
        appState.updateConfig(config)
    }

    func triggerSync(appState: AppState) {
        appState.uploadCoordinator.triggerSync()
    }
}

struct JournalHandoffProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func throwIfFailed(_ command: String) throws {
        guard terminationStatus == 0 else {
            throw JournalHandoffProcessError(command: command, result: self)
        }
    }
}

struct JournalHandoffProcessError: Error, Sendable, CustomStringConvertible {
    let command: String
    let result: JournalHandoffProcessResult

    var description: String {
        "\(command) exited \(result.terminationStatus): \(result.combinedOutput)"
    }
}

enum JournalHandoffProcessRunner {
    static func run(executable: String, arguments: [String]) async throws -> JournalHandoffProcessResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            return JournalHandoffProcessResult(
                terminationStatus: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }.value
    }
}
