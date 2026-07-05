import Testing
import SolstoneCore
@testable import solstone

@Suite("FirstLaunchRoutingTests")
@MainActor
struct FirstLaunchRoutingTests {
    @Test func firstLaunchPermissionsMissingOpensPermissionsOnly() async {
        var openedPermissions = false
        var openedService = false
        var checkedPermissions = false

        await FirstLaunchRouting.route(
            config: AppConfig(),
            waitForPermissionCheck: { checkedPermissions = true },
            permissionsMissing: { true },
            openPermissions: { openedPermissions = true },
            openService: { openedService = true }
        )

        #expect(checkedPermissions)
        #expect(openedPermissions)
        #expect(!openedService)
    }

    @Test func firstLaunchUnconfiguredServiceOpensService() async {
        var openedPermissions = false
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: { openedPermissions = true },
            openService: { openedService = true }
        )

        #expect(!openedPermissions)
        #expect(openedService)
    }

    @Test func firstLaunchConfiguredExternalServiceNoops() async {
        var openedPermissions = false
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: "https://example.com", serverKey: "key", serviceMode: .external),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: { openedPermissions = true },
            openService: { openedService = true }
        )

        #expect(!openedPermissions)
        #expect(!openedService)
    }

    @Test func firstLaunchExternalLoopbackNoops() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: ServiceMode.bundledServiceURL, serverKey: "key", serviceMode: .external),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true }
        )

        #expect(!openedService)
    }

    @Test func firstLaunchBundledModeOpensService() async {
        var openedService = false

        await FirstLaunchRouting.route(
            config: AppConfig(serverURL: ServiceMode.bundledServiceURL, serverKey: "key", serviceMode: .bundled),
            waitForPermissionCheck: {},
            permissionsMissing: { false },
            openPermissions: {},
            openService: { openedService = true }
        )

        #expect(openedService)
    }

    @Test func firstLaunchBundledModeIsIdempotent() async {
        var permissionOpenCount = 0
        var serviceOpenCount = 0

        for _ in 0..<2 {
            await FirstLaunchRouting.route(
                config: AppConfig(serverURL: ServiceMode.bundledServiceURL, serverKey: "key", serviceMode: .bundled),
                waitForPermissionCheck: {},
                permissionsMissing: { false },
                openPermissions: { permissionOpenCount += 1 },
                openService: { serviceOpenCount += 1 }
            )
        }

        #expect(permissionOpenCount == 0)
        #expect(serviceOpenCount == 2)
    }
}
