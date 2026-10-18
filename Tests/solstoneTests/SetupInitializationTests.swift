// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore
import Testing
import UpdateKit
@testable import solstone

@Suite("Setup initialization", .serialized)
@MainActor
struct SetupInitializationTests {
    @Test func failedInitializationQuitsWithoutStartingApplicationWork() async {
        let probe = StartupProbe()
        var failures = 0
        let state = probe.start(load: { _ in throw CocoaError(.fileWriteNoPermission) }) { _ in
            failures += 1
            #expect(probe.constructions == 0)
            return .quit
        }
        #expect(state == nil)
        #expect(failures == 1)
        #expect(probe.quits == 1)
        #expect(probe.exitReasons.first.flatMap { ExitReason(markerString: $0) }?.watchdogExitClass == .ownerIntent)
        #expect(probe.constructions == 0)
        #expect((await probe.harness.entries()).isEmpty)
    }

    @Test func retryAdmitsPreparedConfigurationExactlyOnce() throws {
        let probe = StartupProbe()
        var loads = 0
        var failures = 0
        let state = probe.start(load: { nativeEnabled in
            #expect(nativeEnabled)
            loads += 1
            if loads == 1 { throw CocoaError(.fileWriteNoPermission) }
            return AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false)
        }) { _ in
            failures += 1
            #expect(probe.constructions == 0)
            return .retry
        }
        let ready = try #require(state)
        #expect(loads == 2)
        #expect(failures == 1)
        #expect(probe.quits == 0)
        #expect(probe.exitReasons.isEmpty)
        #expect(probe.stateConstructions == 1)
        #expect(probe.startupConstructions == 1)
        #expect(probe.passedNativeEnabled == true)
        #expect(!ready.config.isScreenCaptureEnabled)
        #expect(!ready.config.isMicrophoneCaptureEnabled)
    }

    @Test func placementRepairNeverLoadsConfigurationOrPresentsItsFailure() async {
        let probe = StartupProbe()
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let context = AppPlacementContext(
            runningBundleURL: URL(fileURLWithPath: "/var/tmp/solstone.app", isDirectory: true),
            canonicalBundleURL: applications.appendingPathComponent("solstone.app"),
            applicationsURL: applications
        )
        var loads = 0
        var failures = 0
        let state = probe.start(decision: .repair(context), load: { _ in
            loads += 1
            throw CocoaError(.fileWriteNoPermission)
        }) { _ in
            failures += 1
            return .quit
        }
        #expect(state == nil)
        #expect(loads == 0)
        #expect(failures == 0)
        #expect(probe.quits == 0)
        #expect(probe.constructions == 0)
        #expect((await probe.harness.entries()).isEmpty)
    }
}

@MainActor
private final class StartupProbe {
    let harness = DiagnosticEvidenceHarness()
    var constructions = 0
    var stateConstructions = 0
    var startupConstructions = 0
    var quits = 0
    var exitReasons: [String] = []
    var passedNativeEnabled: Bool?

    func start(
        decision: AppPlacementDecision = .allowed(.developerBypass),
        load: @escaping @MainActor (Bool) throws -> AppConfig,
        onFailure: @escaping @MainActor (Error) -> SolstoneStartupComposition.ConfigurationFailureChoice
    ) -> AppState? {
        let clock = harness.clock
        return SolstoneStartupComposition.makeNormalStartup(
            decision: decision,
            repairCoordinator: AppPlacementRepairCoordinator { _ in },
            automaticObservationPipelineEnabled: false,
            nativeSetupEnabled: true,
            loadConfiguration: load,
            onConfigurationFailure: onFailure,
            markExpectedExit: { self.exitReasons.append($0) },
            terminateBeforeStartup: {
                #expect(self.exitReasons.count == 1)
                self.quits += 1
            },
            evidenceNow: { clock.now },
            makeEvidenceStore: { _ in
                self.constructions += 1
                return self.harness.store
            },
            makeRecorder: { _, _ in
                self.constructions += 1
                return self.harness.recorder
            },
            makeState: { recorder, _, config, enabled in
                self.constructions += 1
                self.stateConstructions += 1
                self.passedNativeEnabled = enabled
                return AppState.forSnapshot(config: config, recorder: recorder)
            },
            registerSharedState: { _ in self.constructions += 1 },
            makeUpdateController: { _ in
                self.constructions += 1
                return UpdateController(
                    feedURL: nil, publicKey: nil,
                    log: Logger(subsystem: "app.solstone.tests", category: "setup"),
                    errorDomain: "app.solstone.tests.setup",
                    defaults: UserDefaults(suiteName: "SetupInitializationTests.\(UUID().uuidString)")!
                ) { _, _ in nil }
            },
            registerUpdateAnnouncement: { _ in self.constructions += 1 },
            makeStartup: { state, _ in
                self.constructions += 1
                self.startupConstructions += 1
                return state
            }
        )
    }
}
