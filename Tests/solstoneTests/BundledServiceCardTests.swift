// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("BundledServiceCard")
@MainActor
struct BundledServiceCardTests {
    @Test func openDashboardButtonInvokesInjectedOpener() {
        var openedURL: URL?
        let opener: (URL) -> Void = { openedURL = $0 }
        let config = AppConfig(serverURL: "http://localhost:7777")

        opener(bundledDashboardURL(activeServerURL: URL(string: config.serverURL ?? "")))

        #expect(openedURL?.absoluteString == config.serverURL)
    }

    @Test func dashboardURLFallsBackToBundledServiceURLWhenActiveURLMissing() {
        #expect(bundledDashboardURL(activeServerURL: nil).absoluteString == ServiceMode.bundledServiceURL)
    }

    @Test func installedCurrentUsesReadyCopy() {
        #expect(installedServiceMessage(for: .installedCurrent(version: "0.3.2")) == "solstone 0.3.2 is ready")
    }

    @Test func firstLaunchPermissionPromptsNoteAvoidsForbiddenTokens() {
        let copy = firstLaunchPermissionPromptsNote
        #expect(!copy.isEmpty)
        let lowered = copy.lowercased()
        #expect(!lowered.contains("python3.11"))
        #expect(!lowered.contains("server"))
        #expect(!lowered.contains("service"))
        #expect(!lowered.contains("don't worry"))
        #expect(!lowered.contains("don’t worry"))
        #expect(!lowered.contains("it's safe"))
        #expect(!lowered.contains("it’s safe"))
        #expect(!lowered.contains("ignore"))
    }

    @Test func installedUnknownUsesVersionUnavailableCopy() {
        #expect(installedServiceMessage(for: .installedUnknown) == "solstone is installed · couldn't read its version")
    }

    @Test func upgradeFailedStatusMessageUsesSpecLiteral() {
        #expect(upgradeFailedStatusMessage(installedVersion: "0.3.1") == "couldn't upgrade solstone — still running 0.3.1")
    }

    @Test func upgradeFailedRetryButtonTitleUsesSpecLiteral() {
        #expect(upgradeFailedRetryButtonTitle == "try upgrade again")
    }

    @Test func installedUnknownOmitsUpgradeDashboardAndDoctor() {
        #expect(!installedStateShowsDashboardAndDoctor(.installedUnknown))
    }

    @Test func dashboardAndDoctorVisibleForInstalledCurrent() {
        #expect(installedStateShowsDashboardAndDoctor(.installedCurrent(version: "0.3.2")))
    }

    @Test func doctorDisclosureCollapseCancelsRunnerWithin100Milliseconds() async throws {
        var task: Task<Void, Never>? = Task {
            try? await Task.sleep(for: .seconds(5))
        }
        let started = Date()
        var cancelledAt: Date?

        cancelDoctorTask(&task) {
            cancelledAt = Date()
        }

        #expect(task == nil)
        #expect(cancelledAt != nil)
        #expect((cancelledAt ?? .distantFuture).timeIntervalSince(started) < 0.1)
    }
}

@Suite("Doctor status rendering")
struct DoctorStatusRenderingTests {
    @Test func okStatusUsesCheckmarkIcon() {
        #expect(doctorStatusIconName(for: .ok) == "checkmark.circle.fill")
    }

    @Test func warnStatusUsesTriangleIcon() {
        #expect(doctorStatusIconName(for: .warn) == "exclamationmark.triangle.fill")
    }

    @Test func failStatusUsesOctagonIcon() {
        #expect(doctorStatusIconName(for: .fail) == "exclamationmark.octagon.fill")
    }

    @Test func skipStatusUsesMinusIcon() {
        #expect(doctorStatusIconName(for: .skip) == "minus.circle")
    }

    @Test func unknownStatusUsesQuestionIcon() {
        #expect(doctorStatusIconName(for: .unknown("future")) == "questionmark.circle")
    }
}
