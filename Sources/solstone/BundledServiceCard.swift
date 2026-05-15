import AppKit
import SwiftUI
import SolstoneCore

struct BundledServiceCard: View {
    @Bindable var appState: AppState
    var openURL: (URL) -> Void
    @State private var journalURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal")
    @State private var showLogPerRow: [String: Bool] = [:]
    @State private var failureDetailsExpanded = true
    @State private var doctorRunner: SubprocessRunner
    @State private var doctorTask: Task<Void, Never>?
    @State private var doctorResult: Result<DoctorReport, Error>?
    @State private var doctorExpanded = false

    init(
        appState: AppState,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        doctorRunner: SubprocessRunner = SubprocessRunner()
    ) {
        self.appState = appState
        self.openURL = openURL
        self._doctorRunner = State(initialValue: doctorRunner)
    }

    private var installer: SolstoneInstaller {
        appState.installer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch terminalCardState(main: installer.main, probe: installer.probedVersion) {
            case .detecting:
                InstallerProgressRowView(
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
                    installedAffordances
                    autoTestStatusRow
                }
            case .installedOutdated(let installed, let pinned):
                VStack(alignment: .leading, spacing: 12) {
                    Text(installedServiceMessage(for: .installedOutdated(installed: installed, pinned: pinned)))
                    Button("upgrade to \(pinned)") {
                        installer.start(journalURL: journalURL, existingInstallChoice: .createFresh)
                    }
                    .disabled(isInstalling)
                    installedAffordances
                    autoTestStatusRow
                }
            case .installedUnknown:
                Text(installedServiceMessage(for: .installedUnknown))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard case .detecting = installer.main else { return }
            Task { await installer.detect() }
        }
        .onChange(of: doctorExpanded) { _, isExpanded in
            if isExpanded {
                restartDoctor()
            } else {
                cancelDoctor()
            }
        }
    }

    private var absentContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            journalPathRow(canChange: true)

            Button("install solstone for me") {
                installer.start(journalURL: journalURL, existingInstallChoice: .createFresh)
            }
            .disabled(isDetecting)
        }
    }

    private var installedAffordances: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("open journal dashboard") {
                openURL(bundledDashboardURL())
            }

            DisclosureGroup(isExpanded: $doctorExpanded) {
                doctorDisclosureContent
            } label: {
                Text("doctor")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var doctorDisclosureContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("refresh") {
                    restartDoctor()
                }
                .disabled(doctorResult == nil && doctorTask != nil)

                if doctorResult == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("checking...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch doctorResult {
                    case nil:
                        EmptyView()
                    case .success(let report):
                        ForEach(report.checks, id: \.name) { check in
                            doctorCheckRow(check)
                        }
                    case .failure(let error):
                        doctorErrorRow(error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let fix = check.fix, !fix.isEmpty {
                    Text(fix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private func doctorErrorRow(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(doctorErrorPreview(error))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Button("try again") {
                restartDoctor()
            }
        }
    }

    private func restartDoctor() {
        cancelDoctor()
        doctorResult = nil
        let runner = doctorRunner
        doctorTask = Task { @MainActor in
            do {
                let report = try await SolHealthCheck.doctor(runner: runner)
                guard !Task.isCancelled else { return }
                doctorResult = .success(report)
            } catch {
                guard !Task.isCancelled else { return }
                doctorResult = .failure(error)
            }
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
        case .success:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("connected")
                    .foregroundStyle(.secondary)
            }
        case .failure(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.red)
                }
                Button("retry") {
                    Task { await installer.runPostInstallAutoTest() }
                }
            }
        }
    }

    private func failureContent(_ failedState: FailedState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(failureMessage(failedState))
                .foregroundStyle(.secondary)

            rowsContent(showModelsWhenActive: true)

            if let logExcerpt = installer.lastFailureLog, !logExcerpt.isEmpty {
                DisclosureGroup(isExpanded: $failureDetailsExpanded) {
                    ScrollView {
                        Text(logExcerpt)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } label: {
                    Text(failureDetailsExpanded ? "hide details" : "show details")
                        .font(.caption)
                }
            }

            Button("try again") {
                installer.start(journalURL: journalURL, existingInstallChoice: .createFresh)
            }
        }
    }

    @ViewBuilder
    private func rowsContent(showModelsWhenActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([InstallerRow.checkingSystem, .installSolstone, .solSetup, .registering], id: \.rawValue) { row in
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
            label: label(for: row),
            status: status,
            progress: progress,
            isExpanded: Binding(
                get: { isLogExpanded(for: row, in: showLogPerRow) },
                set: { showLogPerRow[row.rawValue] = $0 }
            )
        )
    }

    private func journalPathRow(canChange: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("your journal lives in:")
                    .font(.headline)

                Text(journalURL.path)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if canChange {
                    Button("change...") {
                        changeJournalPath()
                    }
                }
            }

            if isJournalPathTccRestricted(journalURL) {
                Text("macos may ask permission to write here.")
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

    private var isDetecting: Bool {
        if case .detecting = installer.main { return true }
        return false
    }

    private var isInstalling: Bool {
        switch installer.main {
        case .installingSolstone, .runningSolSetup, .registering:
            return true
        case .detecting, .awaitingChoice, .done, .failed:
            return false
        }
    }

    private func label(for row: InstallerRow) -> String {
        switch row {
        case .checkingSystem:
            return "checking your system"
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
        case .installSolstone(let message),
             .installModels(let message),
             .registering(let message):
            return message
        case .solSetup(_, let message):
            return message
        }
    }
}

func installedServiceMessage(for state: InstallerCardState) -> String {
    switch state {
    case .installedCurrent(let version):
        return "solstone \(version) is ready"
    case .installedOutdated(let installed, let pinned):
        return "solstone \(installed) is ready · bundled is \(pinned)"
    case .installedUnknown:
        return "solstone is installed · couldn't read its version"
    default:
        return ""
    }
}

func installedStateShowsDashboardAndDoctor(_ state: InstallerCardState) -> Bool {
    switch state {
    case .installedCurrent, .installedOutdated:
        return true
    default:
        return false
    }
}

func bundledDashboardURL() -> URL {
    URL(string: ServiceMode.bundledServiceURL)!
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

func doctorErrorPreview(_ error: Error) -> String {
    String(error.localizedDescription.prefix(200))
}

func cancelDoctorTask(_ task: inout Task<Void, Never>?, cancelRunner: () -> Void) {
    task?.cancel()
    task = nil
    cancelRunner()
}
