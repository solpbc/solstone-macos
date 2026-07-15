// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SolstoneStartupPlanner")
struct SolstoneStartupPlannerTests {
    @Test func repairModeDoesNotInvokeNormalStartupFactory() throws {
        var normalFactoryInvoked = false
        let context = placementContext()

        do {
            let _: String = try SolstoneStartupPlanner.buildNormalStartup(
                decision: .repair(context),
                makeNormal: {
                    normalFactoryInvoked = true
                    return "normal"
                },
                repair: { _ in
                    throw StartupPlannerTestError.repair
                }
            )
            Issue.record("expected repair branch to throw")
        } catch StartupPlannerTestError.repair {
            // Expected terminal branch surrogate.
        }

        #expect(!normalFactoryInvoked)
    }

    @Test func canonicalModeInvokesNormalStartupFactoryOnce() throws {
        var normalFactoryInvocations = 0

        let startup: String = try SolstoneStartupPlanner.buildNormalStartup(
            decision: .allowed(.canonical),
            makeNormal: {
                normalFactoryInvocations += 1
                return "normal"
            },
            repair: { _ in
                throw StartupPlannerTestError.repair
            }
        )

        #expect(startup == "normal")
        #expect(normalFactoryInvocations == 1)
    }

    private func placementContext() -> AppPlacementContext {
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let canonicalURL = applicationsURL.appendingPathComponent("solstone.app", isDirectory: true)
        let runningURL = URL(fileURLWithPath: "/tmp/solstone.app", isDirectory: true)
        return AppPlacementContext(
            runningBundleURL: runningURL,
            canonicalBundleURL: canonicalURL,
            applicationsURL: applicationsURL,
            runningStandardizedURL: runningURL.standardizedFileURL,
            runningResolvedURL: runningURL.standardizedFileURL.resolvingSymlinksInPath(),
            canonicalStandardizedURL: canonicalURL.standardizedFileURL,
            canonicalResolvedURL: canonicalURL.standardizedFileURL.resolvingSymlinksInPath(),
            pathLooksTranslocated: false
        )
    }
}

private enum StartupPlannerTestError: Error {
    case repair
}
