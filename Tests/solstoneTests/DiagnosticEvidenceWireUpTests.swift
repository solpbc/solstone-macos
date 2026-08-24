// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
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
}
