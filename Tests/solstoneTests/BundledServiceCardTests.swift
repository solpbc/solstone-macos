// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
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

    @Test func sanitizerHidesRawRedirectionCopy() {
        #expect(
            sanitizedInlineFailureMessage("'observer' moved to 'journal observer' — run that instead.")
            == UICopy.INSTALLER_INLINE_FAILURE_GENERIC
        )
    }

    @Test func sanitizerHidesRawBackendPatterns() {
        let rawMessages = [
            "first line\nsecond line",
            "Traceback (most recent call last): ...",
            "error: something failed",
            "try `journal observer create`",
            "command not found",
        ]

        for message in rawMessages {
            #expect(sanitizedInlineFailureMessage(message) == UICopy.INSTALLER_INLINE_FAILURE_GENERIC)
        }
    }

    @Test func sanitizerPassesThroughCleanShortMessages() {
        #expect(sanitizedInlineFailureMessage("no network connection") == "no network connection")
    }

    @Test func sanitizerKeepsUpgradeStatusSummary() {
        let summary = upgradeFailedStatusMessage(installedVersion: "0.4.7")
        #expect(sanitizedInlineFailureMessage(summary) == "couldn't upgrade solstone — still running 0.4.7")
    }

    @Test func failureDiagnosticRetainsRawRedirectionText() {
        let raw = "'observer' moved to 'journal observer' — run that instead."
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(errorMessage: raw, logExcerpt: raw),
            doctorReport: nil
        )

        #expect(markdown.contains(raw))
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

    @Test func failureDiagnosticFreshInstallIncludesStepErrorCodeCategoryDoctorChecksAndSupport() {
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(
                stepIndex: 3,
                stepTotal: 5,
                currentStep: "doctor",
                errorCode: "port_in_use_non_interactive",
                errorMessage: "port 7657 is already in use",
                logExcerpt: "<verbatim log>"
            ),
            doctorReport: DoctorReport(checks: [
                DoctorCheck(
                    name: "port availability",
                    status: .fail,
                    severity: nil,
                    detail: "port 7657 is already in use",
                    fix: nil
                ),
                DoctorCheck(
                    name: "journal command",
                    status: .warn,
                    severity: nil,
                    detail: "setup state needs attention",
                    fix: nil
                ),
            ], summary: nil)
        )

        #expect(markdown == """
these details came from the solstone installer failure card.
share them with a coding agent or support to diagnose the failure below.

about solstone-macos: it installs solstone for you, bundling a python runtime
and uv, installing the solstone python package into
~/Library/Application Support/sol/runtime, then running `journal setup`
(steps: doctor, journal, models, skills, wrapper, service). this report was
captured at the step that failed.

phase: setting up your journal
step: 3/5 · doctor
error: [port_in_use_non_interactive] port 7657 is already in use
category: unknown

versions:
- app: 0.4.6 (42)
- bundled solstone pinned: 0.4.6
- bundled python build: 20260510
- bundled uv: 0.11.13

system:
- macOS: 15.5.0
- arch: arm64

doctor checks:
- port availability · fail · port 7657 is already in use
- journal command · warn · setup state needs attention

dig deeper:
- runtime: ~/Library/Application Support/sol/runtime
- sol: ~/.local/bin/sol
- repo: https://github.com/solpbc/solstone-macos
- log show: /usr/bin/log show --predicate 'subsystem == "app.solstone.observer" AND category == "setup"' --last 30m --info --debug --style compact

log excerpt:
```
<verbatim log>
```

get help → https://support.solstone.app
""")
    }

    @Test func failureDiagnosticOmitsStepWhenProgressIsIncomplete() {
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(stepIndex: 3, stepTotal: 5, currentStep: nil),
            doctorReport: nil
        )

        #expect(!markdown.contains("\nstep:"))
    }

    @Test func failureDiagnosticOmitsErrorCodePrefixWhenAbsent() {
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(errorCode: nil, errorMessage: "setup did not finish"),
            doctorReport: nil
        )

        #expect(markdown.contains("\nerror: setup did not finish\n"))
        #expect(!markdown.contains("\nerror: ["))
    }

    @Test func failureDiagnosticOmitsDoctorSectionWhenReportAbsent() {
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(installedVersion: "0.4.5", logExcerpt: "upgrade details"),
            doctorReport: nil
        )

        #expect(!markdown.contains("\ndoctor checks:"))
    }

    @Test func failureDiagnosticFiltersDoctorChecksToFailuresAndWarnings() {
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(),
            doctorReport: DoctorReport(checks: [
                DoctorCheck(name: "ok check", status: .ok, severity: nil, detail: "ok", fix: nil),
                DoctorCheck(name: "warn check", status: .warn, severity: nil, detail: "warn detail", fix: nil),
                DoctorCheck(name: "fail check", status: .fail, severity: nil, detail: nil, fix: nil),
                DoctorCheck(name: "skip check", status: .skip, severity: nil, detail: "skip", fix: nil),
                DoctorCheck(name: "future check", status: .unknown("future"), severity: nil, detail: "future", fix: nil),
            ], summary: nil)
        )

        #expect(markdown.contains("- warn check · warn · warn detail"))
        #expect(markdown.contains("- fail check · fail"))
        #expect(!markdown.contains("ok check"))
        #expect(!markdown.contains("skip check"))
        #expect(!markdown.contains("future check"))
    }

    @Test func failureDiagnosticUpgradeIncludesInstalledToPinnedLine() {
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(installedVersion: "0.4.5"),
            doctorReport: nil
        )

        #expect(markdown.contains("- upgrade: installed 0.4.5 → pinned 0.4.6"))
    }

    @Test func failureDiagnosticUsesUpgradeErrorDetailsAsLogExcerpt() {
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(installedVersion: "0.4.5", logExcerpt: "uv tool install solstone\nerror: network is unreachable"),
            doctorReport: nil
        )

        #expect(markdown.contains("""
log excerpt:
```
uv tool install solstone
error: network is unreachable
```
"""))
    }

    @Test func failureDiagnosticSectionsRenderInStableOrder() throws {
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(stepIndex: 3, stepTotal: 5, currentStep: "doctor"),
            doctorReport: DoctorReport(checks: [
                DoctorCheck(name: "port availability", status: .fail, severity: nil, detail: "port unavailable", fix: nil),
            ], summary: nil)
        )
        let markers = [
            "these details came from",
            "\nphase:",
            "\nstep:",
            "\nerror:",
            "\ncategory:",
            "\nversions:",
            "\nsystem:",
            "\ndoctor checks:",
            "\ndig deeper:",
            "\nlog excerpt:",
            "\nget help → https://support.solstone.app",
        ]
        var previous = markdown.startIndex
        for marker in markers {
            let range = try #require(markdown.range(of: marker))
            #expect(range.lowerBound >= previous)
            previous = range.lowerBound
        }
    }

    @Test func failureDiagnosticAvoidsForbiddenPublicHygieneTokens() {
        let markdown = buildFailureDiagnosticMarkdown(
            diagnosticInput(logExcerpt: "target: ~/Library/Application Support/sol/runtime\nsol: ~/.local/bin/sol"),
            doctorReport: DoctorReport(checks: [
                DoctorCheck(name: "journal command", status: .warn, severity: nil, detail: "setup state needs attention", fix: nil),
            ], summary: nil)
        )
        let lowered = markdown.lowercased()
        for token in ["hopper", "lode", "extro", "/home/", "vpe/", "cmo/"] {
            #expect(!lowered.contains(token))
        }
        #expect(markdown.contains("https://github.com/solpbc/solstone-macos"))
        #expect(markdown.contains("~/Library/Application Support/sol/runtime"))
        #expect(markdown.contains("~/.local/bin/sol"))
        #expect(markdown.contains("https://support.solstone.app"))
    }

    @Test func failureDiagnosticIsByteIdenticalForSameInput() {
        let input = diagnosticInput(stepIndex: 3, stepTotal: 5, currentStep: "doctor", logExcerpt: "stable log")
        let report = DoctorReport(checks: [
            DoctorCheck(name: "journal command", status: .warn, severity: nil, detail: "setup state needs attention", fix: nil),
        ], summary: nil)

        let first = buildFailureDiagnosticMarkdown(input, doctorReport: report)
        let second = buildFailureDiagnosticMarkdown(input, doctorReport: report)

        #expect(Array(first.utf8) == Array(second.utf8))
    }

    @Test func copyFailureDiagnosticInvokesInjectedClipboardAndSetsCopied() {
        let markdown = "diagnostic text"
        var copiedText: String?
        var copied = false
        let binding = Binding<Bool>(
            get: { copied },
            set: { copied = $0 }
        )

        copyFailureDiagnostic(markdown: markdown, copyToClipboard: { copiedText = $0 }, copied: binding)

        #expect(copiedText == markdown)
        #expect(copied)
    }
}

private func diagnosticInput(
    phase: String = "setting up your journal",
    stepIndex: Int? = nil,
    stepTotal: Int? = nil,
    currentStep: String? = nil,
    errorCode: String? = nil,
    errorMessage: String = "port 7657 is already in use",
    category: String = "unknown",
    appVersion: String = "0.4.6",
    appBuild: String = "42",
    pinnedSolstoneVersion: String = "0.4.6",
    bundledPythonBuild: String = "20260510",
    bundledUVVersion: String = "0.11.13",
    macOSVersion: String = "15.5.0",
    architecture: String = "arm64",
    installedVersion: String? = nil,
    logExcerpt: String? = nil
) -> FailureDiagnosticInput {
    FailureDiagnosticInput(
        phase: phase,
        stepIndex: stepIndex,
        stepTotal: stepTotal,
        currentStep: currentStep,
        errorCode: errorCode,
        errorMessage: errorMessage,
        category: category,
        appVersion: appVersion,
        appBuild: appBuild,
        pinnedSolstoneVersion: pinnedSolstoneVersion,
        bundledPythonBuild: bundledPythonBuild,
        bundledUVVersion: bundledUVVersion,
        macOSVersion: macOSVersion,
        architecture: architecture,
        installedVersion: installedVersion,
        logExcerpt: logExcerpt
    )
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
