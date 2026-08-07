// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("AppPlacementRepairCoordinator")
@MainActor
struct AppPlacementRepairCoordinatorTests {
    @Test func registerThenReadyPresentsOnce() {
        let context = placementContext()
        var presented: [AppPlacementContext] = []
        let coordinator = AppPlacementRepairCoordinator { presented.append($0) }

        coordinator.registerRepair(context: context)
        #expect(presented.isEmpty)

        coordinator.signalReadiness()
        coordinator.signalReadiness()

        #expect(presented == [context])
    }

    @Test func readyThenRegisterPresentsOnce() {
        let context = placementContext()
        var presented: [AppPlacementContext] = []
        let coordinator = AppPlacementRepairCoordinator { presented.append($0) }

        coordinator.signalReadiness()
        #expect(presented.isEmpty)

        coordinator.registerRepair(context: context)
        coordinator.registerRepair(context: context)

        #expect(presented == [context])
    }

    @Test func zeroReadyPresentsZero() {
        let context = placementContext()
        var presented: [AppPlacementContext] = []
        let coordinator = AppPlacementRepairCoordinator { presented.append($0) }

        coordinator.registerRepair(context: context)

        #expect(presented.isEmpty)
    }

    @Test func repeatedAndReentrantReadyPresentsOnce() {
        let context = placementContext()
        var presented: [AppPlacementContext] = []
        var coordinator: AppPlacementRepairCoordinator!
        coordinator = AppPlacementRepairCoordinator { presentedContext in
            presented.append(presentedContext)
            coordinator.signalReadiness()
            coordinator.registerRepair(context: presentedContext)
        }

        coordinator.registerRepair(context: context)
        coordinator.signalReadiness()
        coordinator.signalReadiness()

        #expect(presented == [context])
    }

    private func placementContext() -> AppPlacementContext {
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let canonicalURL = applicationsURL.appendingPathComponent("solstone.app", isDirectory: true)
        let runningURL = URL(fileURLWithPath: "/tmp/solstone.app", isDirectory: true)
        return AppPlacementContext(
            runningBundleURL: runningURL,
            canonicalBundleURL: canonicalURL,
            applicationsURL: applicationsURL
        )
    }
}
