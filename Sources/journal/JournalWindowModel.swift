// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntime
import Observation
import SolstoneCore

enum JournalPane: String, CaseIterable, Hashable, Identifiable {
    case home
    case journal
    case runState
    case devices
    case backup
    case startup
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "home"
        case .journal: return "journal"
        case .runState: return "run state"
        case .devices: return "devices"
        case .backup: return "backup"
        case .startup: return "startup"
        case .updates: return "updates"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .journal: return "book.closed"
        case .runState: return "waveform.path.ecg"
        case .devices: return "iphone.gen3"
        case .backup: return "externaldrive"
        case .startup: return "power"
        case .updates: return "arrow.down.circle"
        }
    }
}

enum JournalRunDisplay: String, CaseIterable, Sendable {
    case starting
    case running
    case stopped
    case blocked
    case unknown

    var label: String {
        switch self {
        case .starting: return "starting…"
        case .running: return "running"
        case .stopped: return "stopped"
        case .blocked: return "blocked"
        case .unknown: return "unknown"
        }
    }

    static func derive(state: JournalSupervisorState, runtimeStatus: JournalRuntimeStatus) -> JournalRunDisplay {
        switch state {
        case .blocked:
            return .blocked
        case .materializing, .starting, .waitingForReadiness:
            return .starting
        case .terminating:
            return .stopped
        case .running:
            switch runtimeStatus {
            case .running:
                return .running
            case .restarting(_):
                return .starting
            case .stopped, .stoppedByUser:
                return .stopped
            case .unobserved, .setupNeeded, .unknown:
                return .unknown
            }
        case .failed:
            switch runtimeStatus {
            case .stopped, .stoppedByUser:
                return .stopped
            case .restarting(_):
                return .starting
            case .unobserved, .running, .setupNeeded, .unknown:
                return .unknown
            }
        case .idle:
            switch runtimeStatus {
            case .stopped, .stoppedByUser:
                return .stopped
            case .restarting(_):
                return .starting
            case .unobserved, .running, .setupNeeded, .unknown:
                return .unknown
            }
        }
    }
}

enum JournalHealthDisplay: String, CaseIterable, Sendable {
    case healthy
    case stopped
    case unknown

    var label: String {
        switch self {
        case .healthy: return "healthy"
        case .stopped: return "stopped"
        case .unknown: return "unknown"
        }
    }
}

@MainActor
@Observable
final class JournalWindowModel {
    typealias ConfigFetch = @Sendable () async throws -> JournalConfig
    typealias NameUpdate = @Sendable (String) async throws -> JournalConfig
    typealias IdentityFetch = @Sendable (String) async -> JournalMark?
    typealias DiskUsageFetch = @Sendable (URL) async -> Int64
    typealias HealthFetch = @Sendable (URL, [String: String]?) async -> JournalHealthCheckResult
    typealias VersionFetch = @Sendable (URL, [String: String]?) async -> String?
    typealias MachineNameProvider = @Sendable () -> String
    typealias NowProvider = @Sendable () -> Date
    typealias IdentityMarkObserver = @MainActor @Sendable (JournalMark) -> Void

    @ObservationIgnored private let config: JournalAppConfig
    let supervisor: JournalSupervisor
    @ObservationIgnored private let baseURL: String
    @ObservationIgnored private let fetchConfig: ConfigFetch
    @ObservationIgnored private let updateName: NameUpdate
    @ObservationIgnored private let fetchIdentity: IdentityFetch
    @ObservationIgnored private let fetchDiskUsage: DiskUsageFetch
    @ObservationIgnored private let fetchHealth: HealthFetch
    @ObservationIgnored private let fetchVersion: VersionFetch
    @ObservationIgnored private let machineNameProvider: MachineNameProvider
    @ObservationIgnored private let now: NowProvider
    @ObservationIgnored private let diskCacheDuration: TimeInterval
    @ObservationIgnored var onIdentityMark: IdentityMarkObserver?
    let devicesModel: JournalDevicesModel

    var selectedPane: JournalPane = .home
    var journalName = ""
    var draftJournalName = ""
    var nameError: String?
    var isSavingName = false
    var identityMark: JournalMark?
    var diskUsageBytes: Int64?
    var healthDisplay: JournalHealthDisplay = .unknown
    var runtimeVersion = "unknown"
    var appVersion: String

    private var hasLoadedConfig = false
    private var identityFetchStarted = false
    private var diskUsageLoadedAt: Date?

    init(
        config: JournalAppConfig,
        supervisor: JournalSupervisor,
        baseURL: String = "http://127.0.0.1:5015",
        configClient: JournalConfigClient = JournalConfigClient(),
        identitySession: URLSession = .shared,
        fetchConfig: ConfigFetch? = nil,
        updateName: NameUpdate? = nil,
        fetchIdentity: IdentityFetch? = nil,
        fetchDiskUsage: DiskUsageFetch? = nil,
        fetchHealth: HealthFetch? = nil,
        fetchVersion: VersionFetch? = nil,
        devicesModel: JournalDevicesModel? = nil,
        onIdentityMark: IdentityMarkObserver? = nil,
        machineNameProvider: @escaping MachineNameProvider = {
            let localized = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let localized, !localized.isEmpty { return localized }
            return ProcessInfo.processInfo.hostName
        },
        now: @escaping NowProvider = { Date() },
        diskCacheDuration: TimeInterval = 30,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    ) {
        let defaultIdentityFetcher = JournalIdentityFetcher(session: identitySession)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.config = config
        self.supervisor = supervisor
        self.baseURL = trimmedBaseURL
        self.fetchConfig = fetchConfig ?? { try await configClient.fetchConfig() }
        self.updateName = updateName ?? { try await configClient.updateJournalName($0) }
        self.fetchIdentity = fetchIdentity ?? { baseURL in
            await defaultIdentityFetcher.fetch(baseURL: baseURL)
        }
        self.fetchDiskUsage = fetchDiskUsage ?? { await JournalDiskUsage.calculateBytes(under: $0) }
        self.fetchHealth = fetchHealth ?? { binary, environment in
            await JournalHealthCheck.run(journalBinary: binary, environment: environment)
        }
        self.fetchVersion = fetchVersion ?? { binary, environment in
            await JournalHealthCheck.version(journalBinary: binary, environment: environment)
        }
        self.machineNameProvider = machineNameProvider
        self.now = now
        self.diskCacheDuration = diskCacheDuration
        self.onIdentityMark = onIdentityMark
        self.appVersion = appVersion
        self.devicesModel = devicesModel ?? JournalDevicesModel(client: JournalDevicesClient(baseURL: trimmedBaseURL))
    }

    var isConfigured: Bool {
        config.journalRoot != nil
    }

    var journalRootPath: String {
        config.journalRoot?.path ?? "not set"
    }

    var launchAtLoginEnabled: Bool {
        config.launchAtLoginEnabled
    }

    var runDisplay: JournalRunDisplay {
        JournalRunDisplay.derive(state: supervisor.state, runtimeStatus: supervisor.runtimeStatus)
    }

    var displayName: String {
        let trimmedName = journalName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        if let identityMark {
            let words = identityMark.words
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !words.isEmpty {
                return words.joined(separator: " · ")
            }
        }
        let machineName = machineNameProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        return machineName.isEmpty ? "your journal" : machineName
    }

    var unconfiguredMessage: String? {
        isConfigured ? nil : "nothing here yet. creating your journal comes next."
    }

    var diskUsageValue: String {
        guard let diskUsageBytes else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: diskUsageBytes, countStyle: .file)
    }

    func prepareForWindowOpen() {
        selectedPane = .home
        hasLoadedConfig = false
        identityFetchStarted = false
        devicesModel.resetTransientState()
    }

    func loadForWindowOpen() async {
        guard isConfigured else { return }
        await fetchIdentityIfNeeded()
        await loadConfigIfNeeded()
    }

    func applyFirstRunLanding(identityMark: JournalMark?, draftName: String, nameError: String?) {
        self.identityMark = identityMark
        identityFetchStarted = true
        if let validatedMark = identityMark.flatMap(JournalMark.validate) {
            onIdentityMark?(validatedMark)
        }

        let trimmedDraftName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDraftName.isEmpty, draftJournalName.isEmpty {
            draftJournalName = trimmedDraftName
        }
        if let nameError {
            self.nameError = nameError
        }
    }

    func handlePaneOpen(_ pane: JournalPane) {
        switch pane {
        case .journal:
            invalidateDiskUsage()
            Task { await loadDiskUsageIfNeeded() }
        case .runState:
            Task { await refreshRunState() }
        case .devices:
            Task { await devicesModel.loadDevices() }
        case .home, .backup, .startup, .updates:
            break
        }
    }

    func fetchIdentityIfNeeded() async {
        guard !identityFetchStarted else { return }
        identityFetchStarted = true
        let fetchedMark = await fetchIdentity(baseURL)
        identityMark = fetchedMark
        if let validatedMark = fetchedMark.flatMap(JournalMark.validate) {
            onIdentityMark?(validatedMark)
        }
    }

    func loadConfigIfNeeded() async {
        guard !hasLoadedConfig else { return }
        do {
            let loaded = try await fetchConfig()
            applyConfig(loaded)
            hasLoadedConfig = true
            nameError = nil
        } catch {
            hasLoadedConfig = false
        }
    }

    func saveDraftJournalName() async {
        let newName = draftJournalName.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousName = journalName
        let previousDraft = draftJournalName
        journalName = newName
        draftJournalName = newName
        nameError = nil
        isSavingName = true

        do {
            let updated = try await updateName(newName)
            applyConfig(updated)
        } catch {
            journalName = previousName
            draftJournalName = previousDraft
            nameError = "couldn't save name"
        }
        isSavingName = false
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        config.setLaunchAtLoginEnabled(enabled)
    }

    func startJournal() {
        guard let root = config.journalRoot else { return }
        Task {
            _ = await supervisor.start(journalRoot: root)
            await refreshRunState()
        }
    }

    func stopJournal() {
        Task {
            _ = await supervisor.stop()
            await refreshRunState()
        }
    }

    func restartJournal() {
        Task {
            _ = await supervisor.restart()
            await refreshRunState()
        }
    }

    func loadDiskUsageIfNeeded() async {
        guard let root = config.journalRoot else {
            diskUsageBytes = nil
            return
        }
        if let diskUsageLoadedAt, now().timeIntervalSince(diskUsageLoadedAt) < diskCacheDuration {
            return
        }
        diskUsageBytes = await fetchDiskUsage(root)
        diskUsageLoadedAt = now()
    }

    func invalidateDiskUsage() {
        diskUsageLoadedAt = nil
    }

    func refreshRunState() async {
        guard let binary = supervisor.journalBinaryURL else {
            healthDisplay = .unknown
            runtimeVersion = "unknown"
            return
        }
        let environment = supervisor.journalRuntimeEnvironment
        switch await fetchHealth(binary, environment) {
        case .healthy:
            healthDisplay = .healthy
        case .stopped:
            healthDisplay = .stopped
        case .unknown:
            healthDisplay = .unknown
        }
        runtimeVersion = await fetchVersion(binary, environment) ?? "unknown"
    }

    private func applyConfig(_ config: JournalConfig) {
        journalName = config.journal.name
        draftJournalName = config.journal.name
    }
}
