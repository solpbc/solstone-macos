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
            findSolBinary: { nil },
            healthCheck: { _ in true }
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
            findSolBinary: { nil },
            healthCheck: { _ in true }
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
            findSolBinary: { nil },
            healthCheck: { _ in false }
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
            findSolBinary: { "/usr/bin/sol" },
            healthCheck: { _ in true }
        )

        #expect(!openedService)
    }

    @Test func firstLaunch_localhostMissingSol_opensService() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key"),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true },
            findSolBinary: { nil },
            healthCheck: { _ in true }
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
            findSolBinary: { "/usr/bin/sol" },
            healthCheck: { _ in false }
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
            findSolBinary: { nil },
            healthCheck: { _ in false }
        )

        #expect(!openedService)
    }

    @Test func firstLaunch_localhostMissingSol_isIdempotent() async {
        var permissionOpenCount = 0
        var serviceOpenCount = 0

        for _ in 0..<2 {
            await FirstLaunchRouting.route(
                config: AppConfig(serverURL: "http://localhost:5015", serverKey: "key"),
                waitForPermissionCheck: {},
                permissionsMissing: { false },
                openPermissions: { permissionOpenCount += 1 },
                openService: { serviceOpenCount += 1 },
                findSolBinary: { nil },
                healthCheck: { _ in true }
            )
        }

        #expect(permissionOpenCount == 0)
        #expect(serviceOpenCount == 2)
    }
}
