// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import UpdateKit
@testable import solstone

@Suite("Diagnostic evidence wire-up")
struct DiagnosticEvidenceWireUpTests {
    @Test func normalCompositionOwnsTheOnlyProductionStoreConstruction() throws {
        let composition = try readWireUpSource("Sources/solstone/SolstoneStartupComposition.swift")
        let app = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let coordinator = try readWireUpSource("Sources/solstone/CaptureCoordinator.swift")

        #expect(wireUpContains(composition, "SolstoneStartupPlanner.planStartup("))
        #expect(wireUpContains(composition, "let store = makeEvidenceStore(evidenceNow)"))
        #expect(wireUpContains(composition, "let recorder = makeRecorder(store, evidenceNow)"))
        #expect(wireUpContains(composition, "let appState = makeState(recorder, automaticObservationPipelineEnabled)"))
        #expect(wireUpContains(composition, "registerSharedState: @escaping @MainActor (AppState) -> Void = { AppState.shared = $0 }"))
        #expect(wireUpContains(composition, "registerSharedState(appState)"))
        #expect(wireUpContains(composition, "recorder.enqueue(.appLaunch)"))
        #expect(wireUpContains(composition, "if automaticObservationPipelineEnabled {"))
        #expect(wireUpContains(composition, "appState.capture.activate()"))
        #expect(wireUpContains(app, "SolstoneStartupComposition.makeNormalStartup("))
        #expect(!wireUpContains(coordinator, "DiagnosticEvidenceStore("))
        #expect(!wireUpContains(coordinator, "Task { await store.record"))
    }

    @Test func productionDefaultsReachTheLivePermissionPollScheduler() throws {
        let app = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let composition = try readWireUpSource("Sources/solstone/SolstoneStartupComposition.swift")
        let appState = try readWireUpSource("Sources/solstone/AppState.swift")
        let coordinator = try readWireUpSource("Sources/solstone/CaptureCoordinator.swift")
        let scheduler = try readWireUpSource("Sources/solstone/PermissionPollScheduler.swift")

        #expect(wireUpContains(app, "SolstoneStartupComposition.makeNormalStartup("))
        #expect(!app.contains("makeState:"))
        #expect(wireUpContains(composition, """
            makeState: @escaping @MainActor (DiagnosticEvidenceRecorder, Bool) -> AppState = { recorder, pipelineEnabled in
                AppState(
                    automaticObservationPipelineEnabled: pipelineEnabled,
                    recorder: recorder
                )
            },
            """))

        let productionInitAnchor = "notifier: any UserNotifying = UNUserNotificationCenterNotifier(),"
        try #require(appState.components(separatedBy: productionInitAnchor).count == 2)
        let anchorRange = try #require(appState.range(of: productionInitAnchor))
        let initRange = try #require(appState[..<anchorRange.lowerBound].range(of: "    init(", options: .backwards))
        let captureRange = try #require(appState[initRange.lowerBound...].range(of: "        self.capture = capture"))
        let productionInit = String(appState[initRange.lowerBound..<captureRange.upperBound])
        try #require(!productionInit.isEmpty)

        #expect(wireUpContains(productionInit, "let capture = CaptureCoordinator("))
        #expect(!wireUpContains(productionInit, "permissionPollScheduler"))
        #expect(wireUpContains(coordinator, "permissionPollScheduler: PermissionPollScheduler = .live(),"))
        #expect(wireUpContains(coordinator, "self.permissionPollScheduler = permissionPollScheduler"))
        #expect(wireUpContains(coordinator, "permissionPollCancellation = permissionPollScheduler.armPolling"))
        #expect(wireUpContains(scheduler, """
            Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
                delivery()
            }
            """))
    }

    @Test func screenTruthAssignmentsAreContained() throws {
        let enumerator = try #require(FileManager.default.enumerator(
            at: URL(fileURLWithPath: "Sources"),
            includingPropertiesForKeys: nil
        ))
        let sourceURLs = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        let sources = try sourceURLs.map { try readWireUpSource($0.path) }
        let publicAssignmentPattern = #"(?<![A-Za-z])screenRecordingGranted\s*=\s*[^=]"#
        let publicAssignments = sources
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("case ")
                    && trimmed.range(of: publicAssignmentPattern, options: .regularExpression) != nil
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .sorted()

        #expect(publicAssignments.isEmpty)

        let privateMutationPattern = #"storedScreenRecordingGranted\s*=\s*[^=]"#
        let privateMutations = sources
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("private var ")
                    && trimmed.range(of: privateMutationPattern, options: .regularExpression) != nil
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .sorted()

        #expect(privateMutations == ["storedScreenRecordingGranted = evidence == .granted"])
        let allSources = sources.joined(separator: "\n")
        #expect(!allSources.contains("set { capture.screenRecordingGranted"))
    }

    @Test func captureCallbackAndSettingsWriterUsePublicationSeam() throws {
        let coordinator = try readWireUpSource("Sources/solstone/CaptureCoordinator.swift")
        let settings = try readWireUpSource("Sources/solstone/SettingsView.swift")

        #expect(wireUpContains(coordinator, "captureManager.onStateChanged = { [weak self] state in"))
        #expect(wireUpContains(coordinator, "self?.handleCaptureStateChange(state)"))
        #expect(wireUpContains(settings, "appState.capture.publishScreenRecordingPermission(.granted)"))
    }

    @Test @MainActor func terminationAndDeliveryEvidenceUseStateOwnedDependencies() throws {
        let app = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let appState = try readWireUpSource("Sources/solstone/AppState.swift")
        let quit = try readWireUpSource("Sources/solstone/AppQuitCoordinator.swift")
        let upload = try readWireUpSource("Sources/solstone/UploadCoordinator.swift")

        #expect(wireUpContains(app, "private var appKitTerminationSeam = AppKitTerminationSeam()"))
        #expect(wireUpContains(app, "appKitTerminationSeam.applicationShouldTerminate()"))
        #expect(!app.contains("terminateNow"))
        #expect(wireUpContains(app, "AppState.shared?.appQuitCoordinator"))
        #expect(wireUpContains(app, "NSApp.reply(toApplicationShouldTerminate: $0)"))
        #expect(wireUpContains(appState, "private let recorder: DiagnosticEvidenceRecorder"))
        #expect(wireUpContains(appState, "private let logAdapter: DiagnosticEvidenceLoggingAdapter"))

        func constructionSlice(startingAt start: String, endingBefore end: String) -> String? {
            guard let startRange = appState.range(of: start),
                  let endRange = appState[startRange.upperBound...].range(of: end) else {
                return nil
            }
            return String(appState[startRange.lowerBound..<endRange.lowerBound])
        }

        let productionUpload = try #require(constructionSlice(
            startingAt: "        uploadCoordinator = UploadCoordinator(\n            storageManager:",
            endingBefore: "        appQuitCoordinator = makeAppQuitCoordinator("
        ))
        #expect(wireUpContains(productionUpload, "recorder: recorder,"))
        #expect(wireUpContains(productionUpload, "logAdapter: logAdapter"))

        let productionQuit = try #require(constructionSlice(
            startingAt: "        appQuitCoordinator = makeAppQuitCoordinator(\n            setCommitted: { [weak self] committed in",
            endingBefore: "        captureTarget.state = self"
        ))
        #expect(wireUpContains(productionQuit, "recorder: recorder,"))
        #expect(wireUpContains(productionQuit, "logAdapter: logAdapter"))

        let snapshotUpload = try #require(constructionSlice(
            startingAt: "        uploadCoordinator = UploadCoordinator(\n            forSnapshot: storageManager,",
            endingBefore: "        appQuitCoordinator = makeAppQuitCoordinator("
        ))
        #expect(wireUpContains(snapshotUpload, "recorder: recorder,"))
        #expect(wireUpContains(snapshotUpload, "logAdapter: logAdapter"))

        let snapshotQuit = try #require(constructionSlice(
            startingAt: "        appQuitCoordinator = makeAppQuitCoordinator(\n            setCommitted: { _ in },",
            endingBefore: "        visitedSettingsTabs ="
        ))
        #expect(wireUpContains(snapshotQuit, "recorder: recorder,"))
        #expect(wireUpContains(snapshotQuit, "logAdapter: logAdapter"))

        #expect(!wireUpContains(appState, "evidenceDrainCutoffSeconds:"))
        #expect(wireUpContains(quit, "diagnosticEvidenceDrainCutoffSeconds: Double = 2"))
        #expect(wireUpContains(upload, "recorder: DiagnosticEvidenceRecorder = .dormant"))
        #expect(wireUpContains(upload, "logAdapter: DiagnosticEvidenceLoggingAdapter = .live"))
        #expect(UpdateController.stagedInstallRecoveryDelay == .seconds(30))
        #expect(AppQuitCoordinator.diagnosticEvidenceDrainCutoffSeconds < 30)
    }
}
