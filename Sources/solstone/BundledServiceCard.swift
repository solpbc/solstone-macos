import AppKit
import SwiftUI

struct BundledServiceCard: View {
    @Bindable var appState: AppState
    @State private var journalURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal")
    @State private var showLogPerRow: [String: Bool] = [:]
    @State private var failureDetailsExpanded = true

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
                    Text("solstone \(version) is installed")
                    autoTestStatusRow
                }
            case .installedOutdated(let installed, let pinned):
                VStack(alignment: .leading, spacing: 12) {
                    Text("solstone \(installed) is installed - bundled version is \(pinned)")
                    Button("upgrade to \(pinned)") {
                        installer.start(journalURL: journalURL, existingInstallChoice: .createFresh)
                    }
                    .disabled(isInstalling)
                    autoTestStatusRow
                }
            case .installedUnknown:
                Text("solstone is installed (version unavailable)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard case .detecting = installer.main else { return }
            Task { await installer.detect() }
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
