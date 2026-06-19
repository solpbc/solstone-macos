import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("Settings restart contract")
@MainActor
struct SettingsRestartContractTests {
    @Test func registryCoversEveryKnownAppConfigKey() {
        for key in AppConfig.knownKeys {
            #expect(SettingsReloadSemantics.semantic[key] != nil)
        }
    }

    @Test func registryPinsRestartRequiredKeys() {
        for key in ["serverURL", "serverKey", "serviceMode", "journalPath"] {
            #expect(SettingsReloadSemantics.semantic[key] == .restartRequired)
        }
    }

    @Test func registryPinsLiveKeys() {
        let keys = [
            "cacheRetentionDays",
            "microphoneGain",
            "silenceMusic",
            "solInitiatedChatNotificationsEnabled",
            "microphonePriority",
            "excludedApps",
            "excludedTitlePatterns",
            "excludePrivateBrowsing",
            "syncPaused",
            "debugSegments",
            "debugKeepRejectedAudio",
            "loginItemEnabled",
        ]
        for key in keys {
            #expect(SettingsReloadSemantics.semantic[key] == .live)
        }
    }

    @Test func registryPinsAppRestartPseudoKeys() {
        #expect(SettingsReloadSemantics.semantic["screenRecordingGranted"] == .appRestart)
        #expect(SettingsReloadSemantics.semantic["microphoneGranted"] == .appRestart)
    }

    @Test func hookShowsBannerInBundledModeWithAvailableRestart() {
        let state = makeRestartableState()

        state.notifyRestartRequiredSettingSaved()

        #expect(state.restartRequiredBannerVisible)
    }

    @Test func productionSaveServiceDoesNotCallTheHook() throws {
        let source = try readSource("Sources/solstone/SettingsView.swift")

        #expect(!source.contains("notifyRestartRequiredSettingSaved"))
    }

    @Test func saveServiceImmediateSyncRespectsBundledReadinessGate() throws {
        let source = try readSource("Sources/solstone/SettingsView.swift")
        let body = try extract(
            from: source,
            start: "private func saveService(url: String, key: String, mode: ServiceMode)",
            end: "    // MARK: - Microphone Tab"
        )

        #expect(body.contains("if mode != .bundled || appState.journalDependentServicesReady"))
        #expect(body.contains("syncOnStartup()"))
    }

    @Test func bannerRendersExactUICopyLiteral() throws {
        let source = try readSource("Sources/solstone/SettingsView.swift")

        #expect(source.contains("Text(UICopy.SETTINGS_RESTART_REQUIRED_BANNER)"))
    }

    @Test func bannerPrecedesPermissionsRowAndHeadingInServiceSection() throws {
        let source = try readSource("Sources/solstone/SettingsView.swift")
        let section = try extract(
            from: source,
            start: "private var serviceSection: some View",
            end: "private var restartRequiredBanner: some View"
        )

        let banner = try #require(section.range(of: "restartRequiredBanner"))
        let permissions = try #require(section.range(of: "appState.permissionsNeedAttention"))
        let heading = try #require(section.range(of: "serviceTabHeadingText(for: appState.config.serviceMode)"))

        #expect(banner.lowerBound < permissions.lowerBound)
        #expect(permissions.lowerBound < heading.lowerBound)
    }

    @Test func bannerButtonActionCallsRequestJournalRestart() throws {
        let body = try restartRequiredBannerBody()

        #expect(body.contains("appState.requestJournalRestart()"))
        #expect(!body.contains("JournalRestartRunner"))
        #expect(!body.contains("SubprocessRunner"))
        #expect(!body.contains("launchctl"))
        #expect(!body.contains("\"service\", \"restart\""))
        #expect(!body.contains("arguments: [\"restart\"]"))
    }

    @Test func bannerButtonDisablesWhileRestarting() throws {
        let body = try restartRequiredBannerBody()

        #expect(body.contains(".disabled(appState.journalRuntimeStatus.isRestarting)"))
    }

    @Test func bannerStateLivesOnAppStateNotSettingsView() throws {
        let settingsSource = try readSource("Sources/solstone/SettingsView.swift")
        let appStateSource = try readSource("Sources/solstone/AppState.swift")

        #expect(!settingsSource.contains("@State private var restartRequiredBannerVisible"))
        #expect(appStateSource.contains("public internal(set) var restartRequiredBannerVisible: Bool = false"))
    }

    @Test func successfulRestartClearsBannerWhenGenerationMatches() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = makeRestartableState()
        state.notifyRestartRequiredSettingSaved()
        configureRestart(state: state, journalRoot: temp, reprobe: { .reachable })

        state.requestJournalRestart()
        try await waitUntil {
            !state.journalRuntimeStatus.isRestarting && !state.restartRequiredBannerVisible
        }

        #expect(!state.restartRequiredBannerVisible)
    }

    @Test func bundledRestartUsesSupervisedRunnerNotJournalRestartRunner() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = makeRestartableState()
        let factoryCalls = LockedCounter()
        let restartRunner = FakeSubprocessRunner()
        configureRestart(state: state, journalRoot: temp, reprobe: { .reachable })
        state.journalRestartRunnerFactory = { journalBinary, logSink in
            factoryCalls.increment()
            return JournalRestartRunner(
                runner: restartRunner,
                journalPathProvider: { _ in temp.path },
                reprobe: { .reachable },
                logSink: logSink,
                journalBinary: journalBinary
            )
        }

        state.requestJournalRestart()
        try await waitUntil {
            !state.journalRuntimeStatus.isRestarting
        }

        #expect(factoryCalls.count == 0)
        #expect(!restartRunner.invocations.contains { $0.arguments == ["service", "restart"] })
    }

    @Test func runJournalStartRoutesThroughBundledStartupOnly() throws {
        let source = try readSource("Sources/solstone/AppState.swift")
        let body = try extract(
            from: source,
            start: "private func runJournalStart() async",
            end: "    // TODO(v1.1)"
        )

        #expect(body.contains("coordinateBundledJournalStart(journalRoot: configuredJournalRoot()).value"))
        #expect(!body.contains(".start(runtime:"))
    }

    @Test func settingsRelaunchRoutesThroughAppQuitCoordinator() throws {
        let source = try readSource("Sources/solstone/SettingsView.swift")
        let body = try extract(
            from: source,
            start: "private func relaunchApp()",
            end: "    // MARK: - Observer Tab"
        )

        #expect(body.contains("appState.appQuitCoordinator.requestSettingsRestart()"))
        #expect(!body.contains("Process()"))
        #expect(!body.contains("asyncAfter"))
        #expect(!body.contains("NSApp.terminate"))
    }

    @Test func journalLifecycleRequestsUseTaskHandleMutualExclusion() throws {
        let source = try readSource("Sources/solstone/AppState.swift")
        let restartBody = try extract(
            from: source,
            start: "public func requestJournalRestart()",
            end: "public func requestJournalStop()"
        )
        let stopBody = try extract(
            from: source,
            start: "public func requestJournalStop()",
            end: "public func requestJournalStart()"
        )
        let startBody = try extract(
            from: source,
            start: "public func requestJournalStart()",
            end: "    // TODO(v1.1)"
        )

        #expect(restartBody.contains("journalLifecycleBusy"))
        #expect(stopBody.contains("journalLifecycleBusy"))
        #expect(startBody.contains("journalLifecycleBusy"))
    }

    @Test func bundledServiceSectionReferencesJournalStopStartControls() throws {
        let source = try readSource("Sources/solstone/SettingsView.swift")
        let body = try extract(
            from: source,
            start: "private var serviceSection: some View",
            end: "private func tradeoffLine"
        )

        #expect(body.contains("journalStopControl"))
        #expect(body.contains("journalStartControl"))
        #expect(body.contains("AXID.Settings.Service.stopJournalButton"))
        #expect(body.contains("AXID.Settings.Service.startJournalButton"))
        #expect(body.contains("UICopy.STOP_JOURNAL"))
        #expect(body.contains("UICopy.START_JOURNAL"))
        #expect(body.contains("appState.requestJournalStop()"))
        #expect(body.contains("appState.requestJournalStart()"))
    }

    @Test func failedRestartLeavesBannerVisible() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = makeRestartableState()
        state.notifyRestartRequiredSettingSaved()
        let postRestart = diag("post restart")
        configureRestart(state: state, journalRoot: temp, reprobe: { .unreachable(postRestart) })

        state.requestJournalRestart()
        try await waitUntil {
            !state.journalRuntimeStatus.isRestarting && state.errorMessage == "restart failed — journal did not come back"
        }

        #expect(state.restartRequiredBannerVisible)
    }

    @Test func concurrentSaveDuringInFlightLeavesBannerVisible() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = makeRestartableState()
        let gate = RestartGate()
        state.notifyRestartRequiredSettingSaved()
        configureRestart(state: state, journalRoot: temp, reprobe: {
            await gate.waitForRelease()
            return .reachable
        })

        state.requestJournalRestart()
        try await waitUntil { gate.isWaiting }
        state.notifyRestartRequiredSettingSaved()
        gate.release()
        try await waitUntil { !state.journalRuntimeStatus.isRestarting }

        #expect(state.restartRequiredBannerVisible)
    }

    @Test func menubarRestartConcurrentWithVisibleBannerClearsBanner() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = makeRestartableState()
        state.notifyRestartRequiredSettingSaved()
        configureRestart(state: state, journalRoot: temp, reprobe: { .reachable })

        state.requestJournalRestart()
        try await waitUntil {
            !state.journalRuntimeStatus.isRestarting && !state.restartRequiredBannerVisible
        }

        #expect(!state.restartRequiredBannerVisible)
    }

    @Test func bannerClearedOnlyInsideRestartRunners() throws {
        let source = try readSource("Sources/solstone/AppState.swift")
        let matches = ranges(of: "restartRequiredBannerVisible = false", in: source)
        let launchdFunction = try extract(
            from: source,
            start: "private func runJournalRestart() async",
            end: "private func runSupervisedJournalRestart() async"
        )
        let supervisedFunction = try extract(
            from: source,
            start: "private func runSupervisedJournalRestart() async",
            end: "private func emitJournalRestartLog"
        )

        #expect(matches.count == 3)
        #expect(launchdFunction.contains("restartRequiredBannerVisible = false"))
        #expect(supervisedFunction.contains("restartRequiredBannerVisible = false"))
    }

    @Test func liveOnlyRegistryEntriesAreLiveSemantic() {
        let keys = [
            "cacheRetentionDays",
            "microphoneGain",
            "silenceMusic",
            "solInitiatedChatNotificationsEnabled",
            "microphonePriority",
            "excludedApps",
            "excludedTitlePatterns",
            "excludePrivateBrowsing",
            "syncPaused",
            "debugSegments",
            "debugKeepRejectedAudio",
            "loginItemEnabled",
        ]

        for key in keys {
            #expect(SettingsReloadSemantics.semantic[key] == .live)
        }
    }

    @Test func hookInExternalModeDoesNotShowBanner() {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .external))

        state.notifyRestartRequiredSettingSaved()

        #expect(!state.restartRequiredBannerVisible)
    }

    @Test func hookWithBundledUnavailableDoesNotShowBanner() {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))

        state.notifyRestartRequiredSettingSaved()

        #expect(!state.restartRequiredBannerVisible)
    }

    @Test func appStateContainsV1_1RemovalTodo() throws {
        let source = try readSource("Sources/solstone/AppState.swift")
        let hook = try extract(
            from: source,
            start: "TODO(v1.1)",
            end: "private func runJournalRestart() async"
        )

        #expect(hook.contains("notifyRestartRequiredSettingSaved"))
    }

    private func makeRestartableState() -> AppState {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        return state
    }

    private func configureRestart(
        state: AppState,
        journalRoot: URL,
        reprobe: @escaping @Sendable () async -> JournalRuntimeProbeOutcome
    ) {
        let runtime = MaterializedRuntime(key: "restart-test", layout: SolstoneRuntimeLayout(rootURL: journalRoot))
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = RestartRuntimeMaterializer(runtime: runtime)
        state.singleSupervisorGate = RestartSingleSupervisorGate()
        state.supervisedJournalRunner = RestartChildRunner()
        state.journalReadinessGate = RestartReadinessGate(reprobe: reprobe)
    }

    private func diag(_ text: String) -> JournalDiagnostic {
        JournalDiagnostic(commandLabel: "journal health", outputExcerpt: text)
    }

    private func restartRequiredBannerBody() throws -> String {
        let source = try readSource("Sources/solstone/SettingsView.swift")
        return try extract(
            from: source,
            start: "private var restartRequiredBanner: some View",
            end: "private func tradeoffLine"
        )
    }

    private func readSource(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func extract(from source: String, start: String, end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source[startRange.upperBound...].range(of: end))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func ranges(of needle: String, in source: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source[searchStart...].range(of: needle) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-settings-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(predicate())
    }
}

private final class RestartRuntimeMaterializer: RuntimeMaterializing, @unchecked Sendable {
    let runtime: MaterializedRuntime

    init(runtime: MaterializedRuntime) {
        self.runtime = runtime
    }

    func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime {
        runtime
    }
}

private struct RestartSingleSupervisorGate: SingleSupervisorGating {
    func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        .success
    }
}

private final class RestartChildRunner: SupervisedChildRunning, @unchecked Sendable {
    func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws {
    }

    func restart() async throws {
    }

    func stop() async {
    }

    func stopForTermination() async {
    }

    func currentRuntimeKey() async -> String? {
        nil
    }

    func markReady() async {
    }
}

private struct RestartReadinessGate: JournalReadinessChecking {
    let reprobe: @Sendable () async -> JournalRuntimeProbeOutcome

    func waitUntilReady(journalRoot: URL, runtime: MaterializedRuntime, timeout: Duration) async -> JournalReadinessResult {
        switch await reprobe() {
        case .reachable:
            return .ready
        case .binaryMissing:
            return .failed(JournalDiagnostic(commandLabel: "journal health", outputExcerpt: "binary missing"))
        case .unreachable(let diagnostic), .unknown(let diagnostic):
            return .failed(diagnostic)
        }
    }
}

private final class RestartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var isWaiting: Bool {
        lock.withLock { waiting }
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                waiting = true
                if released {
                    return true
                }
                continuations.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            let current = continuations
            continuations.removeAll()
            return current
        }
        for continuation in pending {
            continuation.resume()
        }
    }
}
