import AppKit
import SwiftUI
import Foundation

@MainActor
protocol AppActivator {
    func activate()
}

struct DefaultAppActivator: AppActivator {
    func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum InstallerCardState: Equatable {
    case choice(existingInstall: Bool)
    case progress
    case completion
    case failure(FailedState)
}

enum RowStatus: Equatable {
    case pending
    case running
    case ok
    case failed(message: String)
}

enum InstallerRow: String, CaseIterable {
    case checkingSystem = "row.checkingSystem"
    case installSolstone = "row.installSolstone"
    case solSetup = "row.solSetup"
    case registering = "row.registering"
    case models = "row.models"
}

func cardState(from main: MainState) -> InstallerCardState {
    switch main {
    case .detecting:
        return .progress
    case .awaitingChoice(let existingInstall):
        return .choice(existingInstall: existingInstall)
    case .installingSolstone, .runningSolSetup, .registering:
        return .progress
    case .done:
        return .completion
    case .failed(let failedState):
        return .failure(failedState)
    }
}

func rowStatus(for row: InstallerRow, main: MainState, modelsProgress: ModelsProgress) -> RowStatus {
    switch row {
    case .checkingSystem:
        if case .detecting = main {
            return .running
        }
        return .ok
    case .installSolstone:
        switch main {
        case .detecting, .awaitingChoice:
            return .pending
        case .installingSolstone:
            return .running
        case .runningSolSetup, .registering, .done:
            return .ok
        case .failed(let failedState):
            if case .installSolstone(let message) = failedState {
                return .failed(message: message)
            }
            return .ok
        }
    case .solSetup:
        switch main {
        case .detecting, .awaitingChoice, .installingSolstone:
            return .pending
        case .runningSolSetup:
            return .running
        case .registering, .done:
            return .ok
        case .failed(let failedState):
            switch failedState {
            case .solSetup(_, let message):
                return .failed(message: message)
            case .installSolstone:
                return .pending
            case .registering, .installModels:
                return .ok
            }
        }
    case .registering:
        switch main {
        case .detecting, .awaitingChoice, .installingSolstone, .runningSolSetup:
            return .pending
        case .registering:
            return .running
        case .done:
            return .ok
        case .failed(let failedState):
            switch failedState {
            case .registering(let message):
                return .failed(message: message)
            case .installSolstone, .solSetup:
                return .pending
            case .installModels:
                return .ok
            }
        }
    case .models:
        switch modelsProgress {
        case .idle:
            return .pending
        case .running:
            return .running
        case .done:
            return .ok
        case .failed(let message):
            return .failed(message: message)
        }
    }
}

func currentSubprocessProgress(
    for row: InstallerRow,
    main: MainState,
    modelsProgress: ModelsProgress
) -> SubprocessProgress? {
    switch row {
    case .checkingSystem:
        return nil
    case .installSolstone:
        if case .installingSolstone(let progress) = main {
            return progress
        }
        return nil
    case .solSetup:
        if case .runningSolSetup(let progress) = main {
            return progress
        }
        return nil
    case .registering:
        if case .registering(let progress) = main {
            return progress
        }
        return nil
    case .models:
        if case .running(let progress) = modelsProgress {
            return progress
        }
        return nil
    }
}

func isJournalPathTccRestricted(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let home = (NSHomeDirectory() as NSString).standardizingPath
    let restrictedRoots = [
        home + "/Documents",
        home + "/Desktop",
        home + "/Downloads",
        "/Volumes"
    ]

    for root in restrictedRoots where path == root || path.hasPrefix(root + "/") {
        return true
    }
    return false
}

func isLogExpanded(for row: InstallerRow, in state: [String: Bool]) -> Bool {
    state[row.rawValue, default: false]
}

struct InstallerSetupWindow: View {
    @Bindable var installer: SolstoneInstaller
    var activator: any AppActivator
    var onInstall: (URL, ExistingInstallChoice) -> Void
    var onExisting: () -> Void
    var onRetry: () -> Void
    var onDismiss: () -> Void

    @State private var journalURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal")
    @State private var showLogPerRow: [String: Bool] = [:]

    #if DEBUG
    @State private var debugFixture: DebugFixture = .live
    #endif

    init(
        installer: SolstoneInstaller,
        activator: any AppActivator = DefaultAppActivator(),
        onInstall: @escaping (URL, ExistingInstallChoice) -> Void,
        onExisting: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.installer = installer
        self.activator = activator
        self.onInstall = onInstall
        self.onExisting = onExisting
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            #if DEBUG
            debugPicker
            #endif

            switch cardState(from: installer.main) {
            case .choice(let existingInstall):
                choiceContent(existingInstall: existingInstall)
            case .progress:
                progressContent
            case .completion:
                completionContent
            case .failure(let failedState):
                failureContent(failedState)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 360, alignment: .topLeading)
    }

    private func choiceContent(existingInstall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBlock(title: InstallerCopy.setupTitle, subtitle: InstallerCopy.setupSubtitle)
            journalPathRow(canChange: true)

            HStack(spacing: 10) {
                Button(InstallerCopy.installButton) {
                    onInstall(journalURL, .createFresh)
                }

                Button(InstallerCopy.existingInstallButton, action: onExisting)
            }

            if existingInstall {
                Text(InstallerCopy.existingInstallHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBlock(title: InstallerCopy.setupTitle, subtitle: InstallerCopy.setupSubtitle)
            journalPathRow(canChange: false)
            rowsContent(showModelsWhenActive: true)
        }
    }

    private var completionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBlock(title: InstallerCopy.doneTitle, subtitle: InstallerCopy.doneBody)

            Text(InstallerCopy.donePermissions)
                .foregroundStyle(.secondary)

            Button(InstallerCopy.doneButton, action: onDismiss)
        }
    }

    private func failureContent(_ failedState: FailedState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBlock(title: InstallerCopy.setupTitle, subtitle: failureMessage(failedState))
            rowsContent(showModelsWhenActive: true)
            Button(InstallerCopy.retryButton, action: onRetry)
        }
    }

    private func titleBlock(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(subtitle)
                .foregroundStyle(.secondary)
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
                Text(InstallerCopy.journalPathLabel)
                    .font(.headline)

                Text(journalURL.path)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if canChange {
                    Button(InstallerCopy.changeJournalButton) {
                        changeJournalPath()
                    }
                }
            }

            if isJournalPathTccRestricted(journalURL) {
                Text(InstallerCopy.tccWarningSubtitle)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    func changeJournalPath(runPanel: @MainActor (NSOpenPanel) -> URL? = Self.runPanel) {
        activator.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())

        if let url = runPanel(panel) {
            journalURL = url
        }
    }

    private static func runPanel(_ panel: NSOpenPanel) -> URL? {
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func label(for row: InstallerRow) -> String {
        switch row {
        case .checkingSystem:
            return InstallerCopy.rowCheckingSystem
        case .installSolstone:
            return InstallerCopy.rowInstallSolstone
        case .solSetup:
            return InstallerCopy.rowSolSetup
        case .registering:
            return InstallerCopy.rowRegistering
        case .models:
            return InstallerCopy.rowModels
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

    #if DEBUG
    private var debugPicker: some View {
        Picker("debug state", selection: $debugFixture) {
            ForEach(DebugFixture.allCases) { fixture in
                Text(fixture.rawValue).tag(fixture)
            }
        }
        .onChange(of: debugFixture) { _, fixture in
            guard let sampleState = fixture.sampleState else { return }
            installer.main = sampleState.0
            installer.modelsProgress = sampleState.1
        }
    }
    #endif
}

private struct InstallerProgressRowView: View {
    let label: String
    let status: RowStatus
    let progress: SubprocessProgress?
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.headline)

                    if case .running = status, let currentStep = progress?.currentStep {
                        Text(currentStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if case .failed(let message) = status {
                        Text(InstallerCopy.stepFailedPrefix + message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                if let progress, !progress.renderedLog.isEmpty {
                    Button(isExpanded ? InstallerCopy.hideLogLabel : InstallerCopy.showLogLabel) {
                        isExpanded.toggle()
                    }
                    .font(.caption)
                }
            }

            if isExpanded, let renderedLog = progress?.renderedLog, !renderedLog.isEmpty {
                ScrollView {
                    Text(renderedLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 96, maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(InstallerCopy.subprocessPendingLabel)
        case .running:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(InstallerCopy.subprocessRunningLabel)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(InstallerCopy.subprocessOkLabel)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

#if DEBUG
private extension InstallerSetupWindow {
    enum DebugFixture: String, CaseIterable, Identifiable {
        case live
        case detecting
        case choiceFresh
        case choiceExisting
        case installing
        case runningSetup
        case registering
        case modelsRunning
        case done
        case failedInstall
        case failedSetup
        case failedRegistering
        case failedModelsMain

        var id: String { rawValue }

        var sampleState: (MainState, ModelsProgress)? {
            let installProgress = SubprocessProgress(
                phase: "uv tool install solstone",
                renderedLog: "collecting solstone\ninstalling solstone\n"
            )
            let setupProgress = SubprocessProgress(
                phase: "sol setup",
                renderedLog: "setup started\nstep 1/6: doctor\n",
                currentStep: "doctor",
                stepIndex: 1,
                stepTotal: 6
            )
            let registeringProgress = SubprocessProgress(
                phase: "sol observer create",
                renderedLog: "creating observer\n"
            )
            let modelsProgress = SubprocessProgress(
                phase: "sol install-models",
                renderedLog: "installing models\n"
            )

            switch self {
            case .live:
                return nil
            case .detecting:
                return (.detecting, .idle)
            case .choiceFresh:
                return (.awaitingChoice(existingInstall: false), .idle)
            case .choiceExisting:
                return (.awaitingChoice(existingInstall: true), .idle)
            case .installing:
                return (.installingSolstone(installProgress), .idle)
            case .runningSetup:
                return (.runningSolSetup(setupProgress), .idle)
            case .registering:
                return (.registering(registeringProgress), .running(modelsProgress))
            case .modelsRunning:
                return (.done, .running(modelsProgress))
            case .done:
                return (.done, .done)
            case .failedInstall:
                return (.failed(.installSolstone(message: "install failed")), .idle)
            case .failedSetup:
                return (.failed(.solSetup(errorCode: "X1", message: "setup failed")), .idle)
            case .failedRegistering:
                return (.failed(.registering(message: "registration failed")), .done)
            case .failedModelsMain:
                return (.failed(.installModels(message: "models failed")), .failed(message: "models failed"))
            }
        }
    }
}
#endif
