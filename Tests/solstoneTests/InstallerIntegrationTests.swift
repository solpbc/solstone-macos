import CryptoKit
import Foundation
import Testing
@testable import solstone

@Suite("Installer integration")
@MainActor
struct InstallerIntegrationTests {
    @Test func firstLaunch_solAbsent_opensInstaller() async {
        let installer = makeInstaller(solPath: nil)
        var openedInstaller = false
        var openedPermissions = false

        await FirstLaunchRouting.route(
            installer: installer,
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openInstallerSetup: { openedInstaller = true },
            openPermissions: { openedPermissions = true },
            findSolBinary: { nil },
            healthCheck: { _ in true }
        )

        #expect(openedInstaller)
        #expect(!openedPermissions)
        #expect(installer.main == .awaitingChoice(existingInstall: false))
    }

    @Test func firstLaunch_solPresentHealthy_skipsInstaller() async {
        let installer = makeInstaller(solPath: "/usr/bin/sol")
        var openedInstaller = false
        var openedPermissions = false

        await FirstLaunchRouting.route(
            installer: installer,
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openInstallerSetup: { openedInstaller = true },
            openPermissions: { openedPermissions = true },
            findSolBinary: { "/usr/bin/sol" },
            healthCheck: { _ in true }
        )

        #expect(!openedInstaller)
        #expect(!openedPermissions)
        #expect(installer.main == .awaitingChoice(existingInstall: true))
    }

    @Test func firstLaunch_solPresentUnhealthy_opensInstaller() async {
        let installer = makeInstaller(solPath: "/usr/bin/sol")
        var openedInstaller = false
        var openedPermissions = false

        await FirstLaunchRouting.route(
            installer: installer,
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openInstallerSetup: { openedInstaller = true },
            openPermissions: { openedPermissions = true },
            findSolBinary: { "/usr/bin/sol" },
            healthCheck: { _ in false }
        )

        #expect(openedInstaller)
        #expect(!openedPermissions)
        #expect(installer.main == .awaitingChoice(existingInstall: true))
    }

    @Test func firstLaunch_solPresentHealthyPermissionsMissing_opensPermissions() async {
        let installer = makeInstaller(solPath: "/usr/bin/sol")
        var openedInstaller = false
        var openedPermissions = false

        await FirstLaunchRouting.route(
            installer: installer,
            waitForPermissionCheck: {},
            permissionsMissing: { true },
            openInstallerSetup: { openedInstaller = true },
            openPermissions: { openedPermissions = true },
            findSolBinary: { "/usr/bin/sol" },
            healthCheck: { _ in true }
        )

        #expect(!openedInstaller)
        #expect(openedPermissions)
    }

    @Test func installRouting_startsInstallerWithPickedURLAndChoice() async throws {
        let runner = FakeSubprocessRunner()
        let uvURL = try makeUVFixture()
        let journalURL = URL(fileURLWithPath: "/tmp/solstone-picked-journal")
        runner.enqueue("tool", .success())
        runner.enqueue("setup", .success(stdout: setupOK))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(
            runner: runner,
            uvURL: uvURL,
            expectedDigest: sha256(Data("uv\n".utf8)),
            solPath: "/usr/bin/sol"
        )
        defer { installer.cancel() }

        InstallerSceneRouting.install(installer: installer, journalURL: journalURL, choice: .createFresh)
        try await waitUntil { installer.main == .done }

        let setup = try #require(runner.invocations.first { $0.arguments.first == "setup" })
        #expect(setup.arguments.contains(journalURL.path))
    }

    @Test func existingRouting_setsServiceTabAndClosesInstaller() {
        let appState = AppState()
        var openedSettings = false
        var dismissedInstaller = false
        var activated = false

        InstallerSceneRouting.existing(
            appState: appState,
            openSettings: {
                openedSettings = true
                appState.didOpenWindow(.settings)
            },
            dismissInstaller: { dismissedInstaller = true },
            activate: { activated = true }
        )

        #expect(appState.pendingSettingsTab == "service")
        #expect(openedSettings)
        #expect(dismissedInstaller)
        #expect(activated)
        #expect(appState.openSceneIds.contains(.settings))
    }

    @Test func dismissRouting_opensPermissionsWhenMissing() {
        let appState = AppState()
        var openedPermissions = false
        var dismissedInstaller = false
        var activated = false

        InstallerSceneRouting.dismiss(
            appState: appState,
            openPermissions: {
                openedPermissions = true
                appState.didOpenWindow(.settings)
            },
            dismissInstaller: { dismissedInstaller = true },
            activate: { activated = true }
        )

        #expect(appState.pendingSettingsTab == "permissions")
        #expect(openedPermissions)
        #expect(dismissedInstaller)
        #expect(activated)
        #expect(appState.openSceneIds.contains(.settings))
    }

    @Test func retryUsesInstallRoutingAgain() async throws {
        let runner = FakeSubprocessRunner()
        let uvURL = try makeUVFixture()
        runner.enqueue("tool", .success(stderr: Data("boom\n".utf8), exitCode: 1))
        runner.enqueue("tool", .success())
        runner.enqueue("setup", .success(stdout: setupOK))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(
            runner: runner,
            uvURL: uvURL,
            expectedDigest: sha256(Data("uv\n".utf8)),
            solPath: "/usr/bin/sol"
        )
        defer { installer.cancel() }

        InstallerSceneRouting.install(installer: installer, journalURL: URL(fileURLWithPath: "/tmp/retry-journal"), choice: .createFresh)
        try await waitUntil {
            if case .failed(.installSolstone) = installer.main { return true }
            return false
        }

        InstallerSceneRouting.install(installer: installer, journalURL: URL(fileURLWithPath: "/tmp/retry-journal"), choice: .createFresh)
        try await waitUntil { installer.main == .done }

        let toolInvocations = runner.invocations.filter { $0.arguments.first == "tool" }
        #expect(toolInvocations.count == 2)
    }

    @Test func registeringAndModelsRunningCanBeObservedTogether() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: setupOK))
        runner.enqueue("observer", .success(stdout: observerJSON, delay: .milliseconds(500)))
        runner.enqueue("install-models", .success(delay: .milliseconds(500)))
        let installer = makeInstaller(runner: runner, solPath: "/usr/bin/sol")
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)

        try await waitUntil {
            if case .registering = installer.main,
               case .running = installer.modelsProgress {
                return true
            }
            return false
        }
    }

    private func makeInstaller(
        runner: FakeSubprocessRunner = FakeSubprocessRunner(),
        uvURL: URL? = nil,
        expectedDigest: String = BundleConfig.bundledUVSha256,
        solPath: String?
    ) -> SolstoneInstaller {
        SolstoneInstaller(
            uvBinaryURL: uvURL,
            subprocessRunner: runner,
            solBinaryFinder: { solPath },
            browserOpener: { _ in true },
            expectedUVDigest: expectedDigest
        )
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(predicate())
    }

    private func makeUVFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-uv-\(UUID().uuidString)")
        try Data("uv\n".utf8).write(to: url)
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var setupOK: Data {
        Data(#"{"event":"setup.completed","status":"ok"}"#.utf8)
    }

    private var observerJSON: Data {
        Data(#"{"name":"solstone-macos","key":"observer-key","prefix":"observer"}"#.utf8)
    }
}
