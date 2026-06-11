import AppKit
import SwiftUI
import SolstoneCore

struct BundledServiceCard: View {
    @Bindable var appState: AppState
    let allowsLocalJournalActions: Bool
    var openURL: (URL) -> Void
    var copyToClipboard: (String) -> Void
    @State private var journalURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal")
    @State private var showLogPerRow: [String: Bool] = [:]
    @State private var failureDetailsExpanded = false
    @State private var failureDiagnosticCopied = false
    @State private var doctorRunner: any SubprocessRunning
    @State private var doctorTask: Task<Void, Never>?
    @State private var doctorResult: JournalDoctorResult?
    @State private var doctorExpanded = false

    init(
        appState: AppState,
        allowsLocalJournalActions: Bool = true,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        copyToClipboard: @escaping (String) -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        },
        doctorRunner: any SubprocessRunning = SubprocessRunner()
    ) {
        self.appState = appState
        self.allowsLocalJournalActions = allowsLocalJournalActions
        self.openURL = openURL
        self.copyToClipboard = copyToClipboard
        self._doctorRunner = State(initialValue: doctorRunner)
    }

    private var installer: SolstoneInstaller {
        appState.installer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let state = terminalCardState(
                main: installer.main,
                probe: installer.probedVersion,
                failureRecord: installer.upgradeFailureRecord
            )
            AXStateCompanion(
                id: AXID.Installer.terminalState,
                value: state.axToken
            )
            switch state {
            case .detecting:
                InstallerProgressRowView(
                    row: .checkingSystem,
                    label: label(for: .checkingSystem),
                    status: .running,
                    progress: nil,
                    isExpanded: .constant(false)
                )
            case .absent:
                absentContent
            case .installing:
                rowsContent(showModelsWhenActive: true)
            case .failed(let failedState):
                failureContent(failedState)
            case .installedPlaceholder, .done:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("checking version...")
                        .foregroundStyle(.secondary)
                }
            case .installedCurrent(let version):
                VStack(alignment: .leading, spacing: 12) {
                    Text(installedServiceMessage(for: .installedCurrent(version: version)))
                        .accessibilityIdentifier(AXID.Installer.installedMessageState)
                        .accessibilityValue(InstallerCardState.installedCurrent(version: version).axToken)
                    installedAffordances
                    autoTestStatusRow
                }
            case .installedUnknown:
                Text(installedServiceMessage(for: .installedUnknown))
                    .accessibilityIdentifier(AXID.Installer.installedMessageState)
                    .accessibilityValue(InstallerCardState.installedUnknown.axToken)
            case .externallyManaged(let solPath, let probe):
                externalManagedContent(solPath: solPath, probe: probe)
            case .upgradeFailed(let installed, let pinned, let errorDetails):
                upgradeFailureContent(installedVersion: installed, pinnedVersion: pinned, errorDetails: errorDetails)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard case .detecting = installer.main else { return }
            Task { await installer.detect() }
        }
        .onChange(of: doctorExpanded) { _, isExpanded in
            if isExpanded && allowsLocalJournalActions {
                restartDoctor()
            } else {
                cancelDoctor()
            }
        }
    }

    private var absentContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            journalPathRow(canChange: true)

            Text(firstLaunchPermissionPromptsNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("install solstone for me") {
                installer.start(journalURL: journalURL, existingInstallChoice: .createFresh)
            }
            .disabled(isDetecting)
            .accessibilityIdentifier(AXID.Installer.install)
        }
    }

    private var installedAffordances: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("open journal dashboard") {
                openURL(bundledDashboardURL(activeServerURL: URL(string: appState.config.serverURL ?? "")))
            }
            .accessibilityIdentifier(AXID.Installer.openDashboard)

            if allowsLocalJournalActions {
                doctorAffordance
            }
        }
    }

    private func externalManagedContent(solPath: String, probe: VersionProbeResult?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(externalManagedTitle)
                .accessibilityIdentifier(AXID.Installer.externalManagedState)
                .accessibilityValue(InstallerCardState.externallyManaged(solPath: solPath, probe: probe).axToken)
            Text(externalManagedBody)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(externalManagedVersionLine(for: probe))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(externalManagedPathCaption(solPath))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier(AXID.Installer.externalManagedPathState)
                .accessibilityValue(solPath)
        }
    }

    private var doctorAffordance: some View {
        DisclosureGroup(isExpanded: $doctorExpanded) {
            doctorDisclosureContent
        } label: {
            Text("doctor")
                .font(.caption)
        }
        .accessibilityIdentifier(AXID.Installer.doctorDisclosure)
    }

    @ViewBuilder
    private var doctorDisclosureContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("refresh") {
                    restartDoctor()
                }
                .disabled(doctorResult == nil && doctorTask != nil)
                .accessibilityIdentifier(AXID.Installer.doctorRefresh)

                if doctorResult == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("checking...")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            AXStateCompanion(
                id: AXID.Installer.doctorProgressState,
                value: doctorProgressAXToken(for: doctorResult)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appProbeChecks(
                        screenRecordingGranted: appState.screenRecordingGranted,
                        microphoneGranted: appState.microphoneGranted,
                        permissionCheckComplete: appState.initialPermissionCheckComplete,
                        ipcServiceRunning: appState.ipcServiceRunning
                    ), id: \.name) { check in
                        doctorCheckRow(check)
                    }

                    switch doctorResult {
                    case nil:
                        EmptyView()
                    case .report(let report):
                        ForEach(report.checks, id: \.name) { check in
                            doctorCheckRow(check)
                        }
                    case .setupNeeded:
                        doctorErrorRow(UICopy.JOURNAL_STATUS_SETUP_NEEDED)
                    case .stopped(let diagnostic), .unknown(let diagnostic):
                        doctorErrorRow(diagnostic.outputExcerpt ?? diagnostic.commandLabel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier(AXID.Installer.doctorChecklist)
        }
    }

    private func doctorCheckRow(_ check: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: doctorStatusIconName(for: check.status))
                .foregroundStyle(doctorStatusColor(for: check.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(check.name.lowercased())
                    if let severity = check.severity, !severity.isEmpty {
                        Text("· \(severity)")
                            .foregroundStyle(.secondary)
                    }
                }

                if let detail = check.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let fix = check.fix, !fix.isEmpty {
                    Text(fix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.Installer.doctorCheck(check.name))
        .accessibilityValue(check.status.axToken)
    }

    private func doctorErrorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AXID.Installer.doctorErrorState)
            .accessibilityValue(message)

            Button("try again") {
                restartDoctor()
            }
            .accessibilityIdentifier(AXID.Installer.doctorRetry)
        }
    }

    private func restartDoctor() {
        guard allowsLocalJournalActions else { return }
        cancelDoctor()
        doctorResult = nil
        let runner = doctorRunner
        doctorTask = Task { @MainActor in
            let result = await JournalHealthCheck.doctor(runner: runner)
            guard !Task.isCancelled else { return }
            doctorResult = result
            doctorTask = nil
        }
    }

    private func cancelDoctor() {
        cancelDoctorTask(&doctorTask) {
            doctorRunner.cancelAll()
        }
    }

    @ViewBuilder
    private var autoTestStatusRow: some View {
        switch installer.postInstallAutoTest {
        case nil:
            EmptyView()
        case .verifying:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("verifying connection...")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AXID.Installer.autoTestState)
            .accessibilityValue(AutoTestState.verifying.axToken)
        case .success:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("connected")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AXID.Installer.autoTestState)
            .accessibilityValue(AutoTestState.success.axToken)
        case .failure(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.red)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AXID.Installer.autoTestState)
                .accessibilityValue(AutoTestState.failure(message).axToken)
                Button("retry") {
                    Task { await installer.runPostInstallAutoTest() }
                }
                .accessibilityIdentifier(AXID.Installer.autoTestRetry)
            }
        }
    }

    private func failureContent(_ failedState: FailedState) -> some View {
        failureCardBody(
            summary: failureMessage(failedState),
            retryTitle: "try again",
            retryAction: {
                installer.start(journalURL: journalURL, existingInstallChoice: .createFresh)
            },
            rawDetails: installer.lastFailureLog,
            diagnosticMarkdown: buildFailureDiagnosticMarkdown(
                failureDiagnosticInput(failedState),
                doctorReport: successfulDoctorReport
            ),
            showDoctor: false,
            allowsRetry: bundledServiceCardAllowsRetry(
                cardState: .failed(failedState),
                allowsLocalJournalActions: allowsLocalJournalActions
            )
        )
        .overlay(alignment: .topLeading) {
            if case .cleanup(let step, _) = failedState {
                AXStateCompanion(
                    id: AXID.Installer.cleanupStep(step),
                    value: RowStatus.failed(message: failureMessage(failedState)).axToken
                )
            }
        }
    }

    private func upgradeFailureContent(installedVersion: String?, pinnedVersion: String, errorDetails: String) -> some View {
        failureCardBody(
            summary: upgradeFailedStatusMessage(installedVersion: installedVersion, pinnedVersion: pinnedVersion),
            retryTitle: upgradeFailureRetryButtonTitle(installedVersion: installedVersion, pinnedVersion: pinnedVersion),
            retryAction: {
                installer.retryUpgradeFailure(
                    journalURL: journalURL,
                    installedVersion: installedVersion,
                    pinnedVersion: pinnedVersion
                )
            },
            rawDetails: errorDetails,
            diagnosticMarkdown: buildFailureDiagnosticMarkdown(
                upgradeFailureDiagnosticInput(
                    installedVersion: installedVersion,
                    pinnedVersion: pinnedVersion,
                    errorDetails: errorDetails
                ),
                doctorReport: nil
            ),
            showDoctor: bundledServiceCardShowsDoctor(
                cardState: .upgradeFailed(installed: installedVersion, pinned: pinnedVersion, errorDetails: errorDetails),
                allowsLocalJournalActions: allowsLocalJournalActions
            ),
            allowsRetry: bundledServiceCardAllowsRetry(
                cardState: .upgradeFailed(installed: installedVersion, pinned: pinnedVersion, errorDetails: errorDetails),
                allowsLocalJournalActions: allowsLocalJournalActions
            )
        )
    }

    private func failureCardBody(
        summary: String,
        retryTitle: String,
        retryAction: @escaping () -> Void,
        rawDetails: String?,
        diagnosticMarkdown: String,
        showDoctor: Bool,
        allowsRetry: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(sanitizedInlineFailureMessage(summary))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AXID.Installer.failureSummaryState)
                .accessibilityValue(sanitizedInlineFailureMessage(summary))

                if allowsRetry {
                    Button(retryTitle, action: retryAction)
                        .accessibilityIdentifier(AXID.Installer.failureRetry)
                }
            }

            rowsContent(showModelsWhenActive: false)

            if installer.modelsProgress != .idle {
                Divider()
                rowView(.models)
            }

            if let rawDetails, !rawDetails.isEmpty {
                DisclosureGroup(isExpanded: $failureDetailsExpanded) {
                    ScrollView {
                        Text(rawDetails)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier(AXID.Installer.failureLog)
                    .accessibilityValue(rawDetails)
                } label: {
                    Text(failureDetailsExpanded ? "hide details" : "show details")
                        .font(.caption)
                }
                .accessibilityIdentifier(AXID.Installer.failureDetails)
            }

            failureDiagnosticFooter(markdown: diagnosticMarkdown)

            if showDoctor {
                doctorAffordance
            }
        }
    }

    private func failureDiagnosticFooter(markdown: String) -> some View {
        FailureDiagnosticFooter(
            markdown: markdown,
            copyToClipboard: copyToClipboard,
            copied: $failureDiagnosticCopied,
            openURL: openURL
        )
    }

    @ViewBuilder
    private func rowsContent(showModelsWhenActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([InstallerRow.checkingSystem, .cleaningUp, .installSolstone, .solSetup, .registering], id: \.rawValue) { row in
                rowView(row)
            }

            if showModelsWhenActive && installer.modelsProgress != .idle {
                Divider()
                rowView(.models)
            }
        }
    }

    private func rowView(_ row: InstallerRow) -> some View {
        let status = rowStatus(for: row, main: installer.main, modelsProgress: installer.modelsProgress)
        let progress = currentSubprocessProgress(for: row, main: installer.main, modelsProgress: installer.modelsProgress)
        return InstallerProgressRowView(
            row: row,
            label: label(for: row),
            status: status,
            progress: progress,
            isExpanded: Binding(
                get: { isLogExpanded(for: row, in: showLogPerRow) },
                set: { showLogPerRow[row.rawValue] = $0 }
            )
        )
        .overlay(alignment: .topLeading) {
            if row == .models {
                AXStateCompanion(
                    id: AXID.Installer.modelDownloadProgress,
                    value: axModelDownloadPercentString(installer.modelsProgress)
                )
            }
        }
    }

    private func journalPathRow(canChange: Bool) -> some View {
        let isRestricted = isJournalPathTccRestricted(journalURL)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("your journal lives in:")
                    .font(.headline)

                Text(journalURL.path)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier(AXID.Installer.journalPathState)
                    .accessibilityValue(journalURL.path)

                Spacer()

                if canChange {
                    Button("change...") {
                        changeJournalPath()
                    }
                    .accessibilityIdentifier(AXID.Installer.journalChange)
                }
            }

            AXStateCompanion(
                id: AXID.Installer.journalTCCRestrictedState,
                value: String(isRestricted)
            )

            if isRestricted {
                Text("macOS may ask permission to write here.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func changeJournalPath() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())

        if panel.runModal() == .OK, let url = panel.url {
            journalURL = url
        }
    }

    private var successfulDoctorReport: DoctorReport? {
        if case .report(let report) = doctorResult {
            return report
        }
        return nil
    }

    private func failureDiagnosticInput(_ failedState: FailedState) -> FailureDiagnosticInput {
        diagnosticInput(
            phase: label(for: rowForFailure(failedState)),
            errorCode: errorCode(for: failedState),
            errorMessage: failureMessage(failedState),
            installedVersion: nil,
            pinnedVersion: BundleConfig.solstonePinVersion,
            logExcerpt: installer.lastFailureLog
        )
    }

    private func upgradeFailureDiagnosticInput(
        installedVersion: String?,
        pinnedVersion: String,
        errorDetails: String
    ) -> FailureDiagnosticInput {
        let failedState: FailedState?
        if case .failed(let state) = installer.main {
            failedState = state
        } else {
            failedState = nil
        }

        return diagnosticInput(
            phase: failedState.map { label(for: rowForFailure($0)) } ?? label(for: .installSolstone),
            errorCode: failedState.flatMap(errorCode(for:)),
            errorMessage: failedState.map(failureMessage) ?? upgradeFailedStatusMessage(installedVersion: installedVersion, pinnedVersion: pinnedVersion),
            installedVersion: installedVersion,
            pinnedVersion: pinnedVersion,
            logExcerpt: errorDetails
        )
    }

    private func diagnosticInput(
        phase: String,
        errorCode: String?,
        errorMessage: String,
        installedVersion: String?,
        pinnedVersion: String,
        logExcerpt: String?
    ) -> FailureDiagnosticInput {
        let progress = installer.lastSetupProgress
        return FailureDiagnosticInput(
            phase: phase,
            stepIndex: progress?.stepIndex,
            stepTotal: progress?.stepTotal,
            currentStep: progress?.currentStep,
            errorCode: errorCode,
            errorMessage: errorMessage,
            category: installer.lastFailureCategory.map { String(describing: $0) } ?? "unknown",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            pinnedSolstoneVersion: pinnedVersion,
            bundledPythonBuild: BundleConfig.bundledPythonBuild,
            bundledUVVersion: BundleConfig.bundledUVVersion,
            macOSVersion: currentMacOSVersionString(),
            architecture: currentArchitectureString(),
            installedVersion: installedVersion,
            logExcerpt: logExcerpt
        )
    }

    private func errorCode(for failedState: FailedState) -> String? {
        if case .solSetup(let errorCode, _) = failedState {
            return errorCode
        }
        return nil
    }

    private var isDetecting: Bool {
        if case .detecting = installer.main { return true }
        return false
    }

    private func label(for row: InstallerRow) -> String {
        switch row {
        case .checkingSystem:
            return "checking your system"
        case .cleaningUp:
            return "preparing upgrade"
        case .installSolstone:
            return "installing solstone"
        case .solSetup:
            return "setting up your journal"
        case .registering:
            return "registering this observer"
        case .models:
            return "downloading the transcription model (this can take a few minutes)"
        }
    }

    private func failureMessage(_ failedState: FailedState) -> String {
        switch failedState {
        case .cleanup(_, let message):
            return message
        case .installSolstone(let message),
             .installModels(let message),
             .registering(let message),
             .upgradeCutoverFailed(let message):
            return message
        case .solSetup(_, let message):
            return message
        }
    }
}

let firstLaunchPermissionPromptsNote: String =
    "macOS will ask permission for solstone's python runtime on first launch so sol can read transcripts and observations into your journal."

let upgradeFailedRetryButtonTitle = "try upgrade again"
let registerAgainRetryButtonTitle = "try registering again"

func upgradeFailureRetryButtonTitle(installedVersion: String?, pinnedVersion: String) -> String {
    if installedVersion == pinnedVersion {
        return registerAgainRetryButtonTitle
    }
    return upgradeFailedRetryButtonTitle
}

func upgradeFailedStatusMessage(installedVersion: String?, pinnedVersion: String) -> String {
    guard let installedVersion, !installedVersion.isEmpty else {
        return "upgrade may be incomplete — couldn't confirm the running version"
    }
    if installedVersion == pinnedVersion {
        return "upgraded solstone to \(pinnedVersion) — couldn't register this observer"
    }
    return "couldn't upgrade solstone — still running \(installedVersion)"
}

func sanitizedInlineFailureMessage(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return UICopy.INSTALLER_INLINE_FAILURE_GENERIC }

    if trimmed.contains(where: \.isNewline) {
        return UICopy.INSTALLER_INLINE_FAILURE_GENERIC
    }

    let lowercased = trimmed.lowercased()
    let rawSubstrings = [
        "traceback",
        "command not found",
        "run that instead",
        "moved to",
        "deprecated",
        "error:",
    ]
    if rawSubstrings.contains(where: { lowercased.contains($0) }) {
        return UICopy.INSTALLER_INLINE_FAILURE_GENERIC
    }

    if trimmed.contains("`") {
        return UICopy.INSTALLER_INLINE_FAILURE_GENERIC
    }

    let hasQuotedCommandToken = trimmed.range(
        of: #"'[\w][\w .\-/]*'"#,
        options: .regularExpression
    ) != nil
    if hasQuotedCommandToken {
        return UICopy.INSTALLER_INLINE_FAILURE_GENERIC
    }

    let commandTokens = ["observer", "journal", "sol", "uv", "python", "pip"]
    if lowercased.contains(" instead") &&
        commandTokens.contains(where: { lowercased.contains($0) }) {
        return UICopy.INSTALLER_INLINE_FAILURE_GENERIC
    }

    return trimmed
}

func installedServiceMessage(for state: InstallerCardState) -> String {
    switch state {
    case .installedCurrent(let version):
        return "solstone \(version) is ready"
    case .installedUnknown:
        return "solstone is installed · couldn't read its version"
    default:
        return ""
    }
}

let externalManagedTitle = "solstone is managed outside this app"

let externalManagedBody = "this Mac can connect in another-machine mode, or keep using the local journal already set up here."

func externalManagedVersionLine(for probe: VersionProbeResult?) -> String {
    switch probe {
    case nil:
        return "checking version..."
    case .current(let version):
        return "found solstone \(version)"
    case .outdated(let installed, let pinned):
        return "found solstone \(installed); this app includes \(pinned)"
    case .unknown:
        return "couldn't read the solstone version"
    }
}

func externalManagedPathCaption(_ path: String) -> String {
    "using \(path)"
}

func installedStateShowsDashboardAndDoctor(_ state: InstallerCardState) -> Bool {
    switch state {
    case .installedCurrent:
        return true
    default:
        return false
    }
}

func bundledServiceCardShowsDoctor(cardState: InstallerCardState, allowsLocalJournalActions: Bool) -> Bool {
    guard allowsLocalJournalActions else { return false }
    switch cardState {
    case .installedCurrent, .upgradeFailed:
        return true
    case .detecting, .absent, .installing, .failed, .installedPlaceholder, .done, .installedUnknown, .externallyManaged:
        return false
    }
}

func bundledServiceCardAllowsRetry(cardState: InstallerCardState, allowsLocalJournalActions: Bool) -> Bool {
    guard allowsLocalJournalActions else { return false }
    switch cardState {
    case .failed, .upgradeFailed:
        return true
    case .detecting, .absent, .installing, .installedPlaceholder, .done, .installedCurrent, .installedUnknown, .externallyManaged:
        return false
    }
}

func bundledDashboardURL(activeServerURL: URL?) -> URL {
    if let activeServerURL, !activeServerURL.absoluteString.isEmpty {
        return activeServerURL
    }
    return URL(string: ServiceMode.bundledServiceURL)!
}

func doctorStatusIconName(for status: DoctorStatus) -> String {
    switch status {
    case .ok:
        return "checkmark.circle.fill"
    case .warn:
        return "exclamationmark.triangle.fill"
    case .fail:
        return "exclamationmark.octagon.fill"
    case .skip:
        return "minus.circle"
    case .unknown:
        return "questionmark.circle"
    }
}

func doctorStatusColor(for status: DoctorStatus) -> Color {
    switch status {
    case .ok:
        return .green
    case .warn:
        return .orange
    case .fail:
        return .red
    case .skip, .unknown:
        return .secondary
    }
}

func cancelDoctorTask(_ task: inout Task<Void, Never>?, cancelRunner: () -> Void) {
    task?.cancel()
    task = nil
    cancelRunner()
}

struct FailureDiagnosticInput: Equatable {
    let phase: String
    let stepIndex: Int?
    let stepTotal: Int?
    let currentStep: String?
    let errorCode: String?
    let errorMessage: String
    let category: String
    let appVersion: String
    let appBuild: String
    let pinnedSolstoneVersion: String
    let bundledPythonBuild: String
    let bundledUVVersion: String
    let macOSVersion: String
    let architecture: String
    let installedVersion: String?
    let logExcerpt: String?
}

func buildFailureDiagnosticMarkdown(_ input: FailureDiagnosticInput, doctorReport: DoctorReport?) -> String {
    var lines = [
        "these details came from the solstone installer failure card.",
        "share them with a coding agent or support to diagnose the failure below.",
        "",
        "about solstone-macos: it installs solstone for you, bundling a python runtime",
        "and uv, installing the solstone python package into",
        "~/Library/Application Support/sol/runtime, then running `journal setup`",
        "(steps: doctor, journal, models, skills, wrapper, service). this report was",
        "captured at the step that failed.",
        "",
        "phase: \(input.phase)",
    ]

    if let stepIndex = input.stepIndex,
       let stepTotal = input.stepTotal,
       let currentStep = input.currentStep,
       !currentStep.isEmpty {
        lines.append("step: \(stepIndex)/\(stepTotal) · \(currentStep)")
    }

    let errorPrefix: String
    if let errorCode = input.errorCode, !errorCode.isEmpty {
        errorPrefix = "[\(errorCode)] "
    } else {
        errorPrefix = ""
    }
    lines.append("error: \(errorPrefix)\(input.errorMessage)")
    lines.append("category: \(input.category)")

    lines.append(contentsOf: [
        "",
        "versions:",
        "- app: \(input.appVersion) (\(input.appBuild))",
        "- bundled solstone pinned: \(input.pinnedSolstoneVersion)",
        "- bundled python build: \(input.bundledPythonBuild)",
        "- bundled uv: \(input.bundledUVVersion)",
    ])
    if let installedVersion = input.installedVersion, !installedVersion.isEmpty {
        lines.append("- upgrade: installed \(installedVersion) → pinned \(input.pinnedSolstoneVersion)")
    }

    lines.append(contentsOf: [
        "",
        "system:",
        "- macOS: \(input.macOSVersion)",
        "- arch: \(input.architecture)",
    ])

    let doctorLines = doctorReport?.checks.compactMap(failureDiagnosticDoctorLine)
    if let doctorLines, !doctorLines.isEmpty {
        lines.append("")
        lines.append("doctor checks:")
        lines.append(contentsOf: doctorLines)
    }

    lines.append(contentsOf: [
        "",
        "dig deeper:",
        "- runtime: ~/Library/Application Support/sol/runtime",
        "- journal: ~/Library/Application Support/sol/runtime/current/bin/journal (or runtime/bin/journal for legacy installs)",
        "- repo: https://github.com/solpbc/solstone-macos",
        "- log show: /usr/bin/log show --predicate 'subsystem == \"app.solstone.observer\" AND category == \"setup\"' --last 30m --info --debug --style compact",
        "",
        "log excerpt:",
        "```",
        input.logExcerpt?.isEmpty == false ? input.logExcerpt! : "no recent installer detail available",
        "```",
        "",
        "get help → https://support.solstone.app",
    ])

    return lines.joined(separator: "\n")
}

private func failureDiagnosticDoctorLine(_ check: DoctorCheck) -> String? {
    let status: String
    switch check.status {
    case .fail:
        status = "fail"
    case .warn:
        status = "warn"
    case .ok, .skip, .unknown:
        return nil
    }

    let base = "- \(check.name) · \(status)"
    if let detail = check.detail, !detail.isEmpty {
        return "\(base) · \(detail)"
    }
    return base
}

func rowForFailure(_ failedState: FailedState) -> InstallerRow {
    switch failedState {
    case .cleanup:
        return .cleaningUp
    case .installSolstone:
        return .installSolstone
    case .upgradeCutoverFailed:
        return .installSolstone
    case .solSetup:
        return .solSetup
    case .installModels:
        return .models
    case .registering:
        return .registering
    }
}

@MainActor
func copyFailureDiagnostic(markdown: String, copyToClipboard: (String) -> Void, copied: Binding<Bool>) {
    copyToClipboard(markdown)
    copied.wrappedValue = true
}

private struct FailureDiagnosticFooter: View {
    let markdown: String
    let copyToClipboard: (String) -> Void
    @Binding var copied: Bool
    let openURL: (URL) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                copyFailureDiagnostic(markdown: markdown, copyToClipboard: copyToClipboard, copied: $copied)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label("copy error details", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier(AXID.Installer.diagnosticCopy)

            if copied {
                Text("copied ✓")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Installer.diagnosticCopiedState)
                    .accessibilityValue(String(copied))
            }

            Button {
                openURL(failureDiagnosticSupportURL)
            } label: {
                Label("get help", systemImage: "questionmark.circle")
            }
            .buttonStyle(.link)
            .accessibilityIdentifier(AXID.Installer.diagnosticHelp)
        }
    }
}

let failureDiagnosticSupportURL = URL(string: "https://support.solstone.app")!

func currentMacOSVersionString() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}

func currentArchitectureString() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
