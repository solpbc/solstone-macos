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
        for key in ["serverURL", "serverKey", "serviceMode"] {
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

    @Test func bannerButtonActionCallsRequestPipelineRestart() throws {
        let body = try restartRequiredBannerBody()

        #expect(body.contains("appState.requestPipelineRestart()"))
        #expect(!body.contains("PipelineRestartRunner"))
        #expect(!body.contains("SubprocessRunner"))
        #expect(!body.contains("launchctl"))
        #expect(!body.contains("\"service\", \"restart\""))
        #expect(!body.contains("arguments: [\"restart\"]"))
    }

    @Test func bannerButtonDisablesWhileRestarting() throws {
        let body = try restartRequiredBannerBody()

        #expect(body.contains(".disabled(appState.isRestartingPipeline)"))
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

        state.requestPipelineRestart()
        try await waitUntil {
            !state.isRestartingPipeline && !state.restartRequiredBannerVisible
        }

        #expect(!state.restartRequiredBannerVisible)
    }

    @Test func failedRestartLeavesBannerVisible() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = makeRestartableState()
        state.notifyRestartRequiredSettingSaved()
        configureRestart(state: state, journalRoot: temp, reprobe: { .unreachable })

        state.requestPipelineRestart()
        try await waitUntil {
            !state.isRestartingPipeline && state.errorMessage == "restart failed at pipeline check — pipeline did not come back"
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

        state.requestPipelineRestart()
        try await waitUntil { gate.isWaiting }
        state.notifyRestartRequiredSettingSaved()
        gate.release()
        try await waitUntil { !state.isRestartingPipeline }

        #expect(state.restartRequiredBannerVisible)
    }

    @Test func menubarRestartConcurrentWithVisibleBannerClearsBanner() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = makeRestartableState()
        state.notifyRestartRequiredSettingSaved()
        configureRestart(state: state, journalRoot: temp, reprobe: { .reachable })

        state.requestPipelineRestart()
        try await waitUntil {
            !state.isRestartingPipeline && !state.restartRequiredBannerVisible
        }

        #expect(!state.restartRequiredBannerVisible)
    }

    @Test func bannerClearedOnlyInsideRunPipelineRestart() throws {
        let source = try readSource("Sources/solstone/AppState.swift")
        let matches = ranges(of: "restartRequiredBannerVisible = false", in: source)
        let function = try extract(
            from: source,
            start: "private func runPipelineRestart() async",
            end: "private func emitPipelineRestartLog"
        )

        #expect(matches.count == 1)
        #expect(function.contains("restartRequiredBannerVisible = false"))
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
            end: "private func runPipelineRestart() async"
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
        reprobe: @escaping @Sendable () async -> PipelineLivenessProbeOutcome
    ) {
        state.pipelineSolBinaryFinder = { "/usr/bin/sol" }
        state.pipelineRestartRunnerFactory = { solPath, logSink in
            let runner = FakeSubprocessRunner()
            runner.enqueue("ps", .success(stdout: Data()))
            runner.enqueue("service", .success())
            return PipelineRestartRunner(
                runner: runner,
                journalPathProvider: { _ in journalRoot.path },
                terminate: { _ in },
                reprobe: reprobe,
                logSink: logSink,
                solPath: solPath
            )
        }
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
