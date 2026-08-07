// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SolstoneStartupPlanner")
@MainActor
struct SolstoneStartupPlannerTests {
    @Test func modeMapsPlacementDecisions() {
        let context = placementContext()

        #expect(SolstoneStartupPlanner.mode(for: .allowed(.canonical)) == .normal(.canonical))
        #expect(SolstoneStartupPlanner.mode(for: .allowed(.stableLocation)) == .normal(.stableLocation))
        #expect(SolstoneStartupPlanner.mode(for: .allowed(.developerBypass)) == .normal(.developerBypass))
        #expect(SolstoneStartupPlanner.mode(for: .repair(context)) == .repair(context))
    }

    @Test func canonicalPlanStartupBuildsNormalOnceAndNeverPresentsRepair() {
        var normalFactoryInvocations = 0
        var presented: [AppPlacementContext] = []
        let coordinator = AppPlacementRepairCoordinator { presented.append($0) }

        let startup: String? = SolstoneStartupPlanner.planStartup(
            decision: .allowed(.canonical),
            coordinator: coordinator,
            makeNormal: {
                normalFactoryInvocations += 1
                return "normal"
            }
        )

        coordinator.signalReadiness()

        #expect(startup == "normal")
        #expect(normalFactoryInvocations == 1)
        #expect(presented.isEmpty)
    }

    @Test func developerBypassPlanStartupBuildsNormalOnceAndNeverPresentsRepair() {
        var normalFactoryInvocations = 0
        var presented: [AppPlacementContext] = []
        let coordinator = AppPlacementRepairCoordinator { presented.append($0) }

        let startup: String? = SolstoneStartupPlanner.planStartup(
            decision: .allowed(.developerBypass),
            coordinator: coordinator,
            makeNormal: {
                normalFactoryInvocations += 1
                return "normal"
            }
        )

        coordinator.signalReadiness()

        #expect(startup == "normal")
        #expect(normalFactoryInvocations == 1)
        #expect(presented.isEmpty)
    }

    @Test func gateAllowedStableLocationBuildsNormalOnceAndNeverPresentsRepair() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-startup-planner-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Downloads/solstone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var normalFactoryInvocations = 0
        var presented: [AppPlacementContext] = []
        let coordinator = AppPlacementRepairCoordinator { presented.append($0) }
        let decision = AppPlacementGate.evaluate(dependencies: .init(
            bundleURL: bundleURL,
            environment: [:],
            applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true),
            cachesURL: URL(fileURLWithPath: "/different/Caches", isDirectory: true),
            temporaryDirectoryURL: URL(fileURLWithPath: "/different/Temporary", isDirectory: true),
            volumeFacts: { _ in AppPlacementVolumeFacts(isInternal: true, isLocal: true) }
        ))

        let startup: String? = SolstoneStartupPlanner.planStartup(
            decision: decision,
            coordinator: coordinator,
            makeNormal: {
                normalFactoryInvocations += 1
                return "normal"
            }
        )
        coordinator.signalReadiness()

        #expect(decision == .allowed(.stableLocation))
        #expect(startup == "normal")
        #expect(normalFactoryInvocations == 1)
        #expect(presented.isEmpty)
    }

    @Test func repairPlanStartupRegistersRepairAndSkipsNormalFactory() {
        var normalFactoryInvocations = 0
        var presented: [AppPlacementContext] = []
        let context = placementContext()
        let coordinator = AppPlacementRepairCoordinator { presented.append($0) }

        let startup: String? = SolstoneStartupPlanner.planStartup(
            decision: .repair(context),
            coordinator: coordinator,
            makeNormal: {
                normalFactoryInvocations += 1
                return "normal"
            }
        )

        #expect(startup == nil)
        #expect(normalFactoryInvocations == 0)
        #expect(presented.isEmpty)

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
