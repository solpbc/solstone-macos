import Foundation
import JournalRuntime
import JournalRuntimeTestSupport
import Testing
import SolstoneCore
@testable import solstone

@Suite("FirstLaunchRoutingTests")
@MainActor
struct FirstLaunchRoutingTests {
    @Test func firstLaunch_permissionsMissing_opensPermissionsOnly() async {
        var openedPermissions = false
        var openedService = false
        var checkedPermissions = false

        await FirstLaunchRouting.route(
            config: AppConfig(),
            waitForPermissionCheck: { checkedPermissions = true },
            permissionsMissing: { true },
            openPermissions: { openedPermissions = true },
            openService: { openedService = true },
            journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
            healthCheck: { _ in true },
            bundledOutdated: { _ in false }
        )

        #expect(checkedPermissions)
        #expect(openedPermissions)
        #expect(!openedService)
    }

    @Test func firstLaunch_unconfiguredService_opensService() async {
        var openedPermissions = false
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: { openedPermissions = true },
            openService: { openedService = true },
            journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
            healthCheck: { _ in true },
            bundledOutdated: { _ in false }
        )

        #expect(!openedPermissions)
        #expect(openedService)
    }

    @Test func firstLaunch_externalServiceConfigured_noops() async {
        var openedPermissions = false
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "https://example.com", serverKey: "key"),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: { openedPermissions = true },
            openService: { openedService = true },
            journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
            healthCheck: { _ in true },
            bundledOutdated: { _ in false }
        )

        #expect(!openedPermissions)
        #expect(!openedService)
    }

    @Test func firstLaunch_localhostHealthy_noops() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key"),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
            healthCheck: { _ in true },
            bundledOutdated: { _ in false }
        )

        #expect(!openedService)
    }

    @Test func firstLaunch_localhostJournalUnavailable_opensService() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key"),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
            healthCheck: { _ in false },
            bundledOutdated: { _ in false }
        )

        #expect(openedService)
    }

    @Test func firstLaunch_loopbackUnhealthy_opensService() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://127.0.0.1:5015", serverKey: "key"),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
            healthCheck: { _ in false },
            bundledOutdated: { _ in false }
        )

        #expect(openedService)
    }

    @Test func firstLaunch_externalLocalhost_noops() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key", serviceMode: .external),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
            healthCheck: { _ in false },
            bundledOutdated: { _ in false }
        )

        #expect(!openedService)
    }

    @Test func firstLaunch_localhostJournalUnavailable_isIdempotent() async {
        var permissionOpenCount = 0
        var serviceOpenCount = 0

        for _ in 0..<2 {
            await FirstLaunchRouting.route(
                config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key"),
                waitForPermissionCheck: {},
                permissionsMissing: { false },
                openPermissions: { permissionOpenCount += 1 },
                openService: { serviceOpenCount += 1 },
                journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
                healthCheck: { _ in false },
                bundledOutdated: { _ in false }
            )
        }

        #expect(permissionOpenCount == 0)
        #expect(serviceOpenCount == 2)
    }

    @Test func firstLaunch_bundledOutdated_opensService() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key", serviceMode: .bundled),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
            healthCheck: { _ in true },
            bundledOutdated: { _ in true }
        )

        #expect(openedService)
    }

    @Test func firstLaunch_unresolvedBundledRuntime_noops() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key", serviceMode: .bundled),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            journalBinary: { nil },
            healthCheck: { _ in
                Issue.record("healthCheck should not run without a journal binary")
                return false
            },
            bundledOutdated: { _ in
                Issue.record("bundledOutdated should not run without a journal binary")
                return true
            }
        )

        #expect(!openedService)
    }

    @Test func firstLaunch_resolvedBundledRuntime_runsOutdatedAndHealthChecks() async {
        let binary = URL(fileURLWithPath: "/runtime/bin/journal")
        var bundledOutdatedBinary: URL?
        var healthCheckBinary: URL?
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key", serviceMode: .bundled),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            journalBinary: { binary },
            healthCheck: {
                healthCheckBinary = $0
                return true
            },
            bundledOutdated: {
                bundledOutdatedBinary = $0
                return false
            }
        )

        #expect(bundledOutdatedBinary == binary)
        #expect(healthCheckBinary == binary)
        #expect(!openedService)
    }

    @Test func firstLaunch_versionTimeoutIsNotOutdatedAndDoesNotOpenService() async {
        let binary = URL(fileURLWithPath: "/runtime/bin/journal")
        let timeout: Duration = .milliseconds(20)
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(delay: timeout))
        var healthCheckBinary: URL?
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key", serviceMode: .bundled),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            journalBinary: { binary },
            healthCheck: {
                healthCheckBinary = $0
                return true
            },
            bundledOutdated: { binary in
                guard let installed = await JournalHealthCheck.version(
                    journalBinary: binary,
                    runner: runner,
                    timeout: timeout
                ) else {
                    return false
                }
                return installed.compare(BundleConfig.solstonePinVersion, options: .numeric) == .orderedAscending
            }
        )

        #expect(healthCheckBinary == binary)
        #expect(!openedService)
        #expect(runner.invocations.first?.timeout == timeout)
    }

    @Test func firstLaunch_externalOutdated_noops() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key", serviceMode: .external),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            journalBinary: { URL(fileURLWithPath: "/runtime/bin/journal") },
            healthCheck: { _ in false },
            bundledOutdated: { _ in true }
        )

        #expect(!openedService)
    }
}
