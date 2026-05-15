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
            switch cardState(from: installer.main) {
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
                Text("solstone is installed")
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
