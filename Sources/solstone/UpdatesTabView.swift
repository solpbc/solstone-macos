import SwiftUI

struct UpdatesTabView: View {
    @Bindable var controller: UpdateController

    #if DEBUG
    @State private var debugFixture: DebugFixture = .idle
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content

            Spacer(minLength: 0)

            Divider()

            Text(UpdatesCopy.privacyFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)

            #if DEBUG
            Divider()

            Picker("debug state", selection: $debugFixture) {
                ForEach(DebugFixture.allCases) { fixture in
                    Text(fixture.rawValue).tag(fixture)
                }
            }
            .onChange(of: debugFixture) { _, fixture in
                controller.state = fixture.sampleState
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if !controller.canCheckForUpdates {
            titleBlock(
                title: UpdatesCopy.unavailableTitle,
                subtitle: UpdatesCopy.unavailableSubtitle
            )
        } else {
            switch controller.state {
            case .idle:
                titleBlock(
                    title: UpdatesCopy.idleTitle,
                    subtitle: UpdatesCopy.idleSubtitle
                )
                actionRow(primaryTitle: UpdatesCopy.actionCheckNow, primaryAction: controller.checkForUpdates)
            case .checking:
                titleBlock(
                    title: UpdatesCopy.checkingTitle,
                    subtitle: UpdatesCopy.checkingSubtitle
                )
                ProgressView()
                actionRow(primaryTitle: UpdatesCopy.actionCancel, primaryAction: controller.cancel)
            case .updateAvailable(let version, let releaseNotes):
                titleBlock(
                    title: UpdatesCopy.updateAvailableTitle(version: version),
                    subtitle: UpdatesCopy.updateAvailableSubtitle(version: version)
                )
                releaseNotesSection(releaseNotes)
                actionRow(
                    primaryTitle: UpdatesCopy.actionDownload,
                    primaryAction: controller.install,
                    secondaryTitle: UpdatesCopy.actionDismiss,
                    secondaryAction: controller.dismiss
                )
            case .downloading(let version, let receivedBytes, let totalBytes):
                titleBlock(
                    title: UpdatesCopy.downloadingTitle(version: version),
                    subtitle: UpdatesCopy.downloadingSubtitle(receivedBytes: receivedBytes, totalBytes: totalBytes)
                )
                progressView(receivedBytes: receivedBytes, totalBytes: totalBytes)
                actionRow(primaryTitle: UpdatesCopy.actionCancel, primaryAction: controller.cancel)
            case .extracting(let version, let progress):
                titleBlock(
                    title: UpdatesCopy.extractingTitle(version: version),
                    subtitle: UpdatesCopy.extractingSubtitle
                )
                ProgressView(value: min(max(0.9 + (progress * 0.1), 0.9), 1.0))
                actionRow(primaryTitle: nil, primaryAction: nil)
            case .readyToInstall(let version, let releaseNotes):
                titleBlock(
                    title: UpdatesCopy.readyToInstallTitle(version: version),
                    subtitle: UpdatesCopy.readyToInstallSubtitle
                )
                releaseNotesSection(releaseNotes)
                actionRow(
                    primaryTitle: UpdatesCopy.actionInstall,
                    primaryAction: controller.install,
                    secondaryTitle: UpdatesCopy.actionDismiss,
                    secondaryAction: controller.dismiss
                )
            case .installing(let version):
                titleBlock(
                    title: UpdatesCopy.installingTitle(version: version),
                    subtitle: UpdatesCopy.installingSubtitle
                )
                ProgressView()
            case .noUpdateAvailable:
                titleBlock(
                    title: UpdatesCopy.noUpdateAvailableTitle,
                    subtitle: UpdatesCopy.noUpdateAvailableSubtitle
                )
            case .error(let message):
                titleBlock(
                    title: UpdatesCopy.errorTitle,
                    subtitle: message
                )
                actionRow(
                    primaryTitle: UpdatesCopy.actionRetry,
                    primaryAction: controller.checkForUpdates,
                    secondaryTitle: UpdatesCopy.actionDismiss,
                    secondaryAction: controller.dismiss
                )
            }
        }
    }

    private func titleBlock(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)

            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func releaseNotesSection(_ releaseNotes: String?) -> some View {
        if let releaseNotes, !releaseNotes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(UpdatesCopy.releaseNotesTitle)
                    .font(.headline)

                if let markdown = try? AttributedString(markdown: releaseNotes) {
                    Text(markdown)
                } else {
                    Text(releaseNotes)
                }
            }
        }
    }

    @ViewBuilder
    private func progressView(receivedBytes: UInt64, totalBytes: UInt64?) -> some View {
        if let totalBytes, totalBytes > 0 {
            ProgressView(value: Double(receivedBytes), total: Double(totalBytes))
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func actionRow(
        primaryTitle: String?,
        primaryAction: (() -> Void)?,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        if primaryTitle != nil || secondaryTitle != nil {
            HStack {
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle, action: primaryAction)
                }

                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
            }
        }
    }
}

#if DEBUG
private extension UpdatesTabView {
    enum DebugFixture: String, CaseIterable, Identifiable {
        case idle
        case checking
        case updateAvailable
        case downloading
        case extracting
        case readyToInstall
        case installing
        case noUpdateAvailable
        case error

        var id: String { rawValue }

        var sampleState: UpdateState {
            switch self {
            case .idle:
                .idle
            case .checking:
                .checking
            case .updateAvailable:
                .updateAvailable(version: "1.1.0", releaseNotes: "- improved updates\n- fixed bugs")
            case .downloading:
                .downloading(version: "1.1.0", receivedBytes: 1_048_576, totalBytes: 4_194_304)
            case .extracting:
                .extracting(version: "1.1.0", progress: 0.5)
            case .readyToInstall:
                .readyToInstall(version: "1.1.0", releaseNotes: "ready to install")
            case .installing:
                .installing(version: "1.1.0")
            case .noUpdateAvailable:
                .noUpdateAvailable
            case .error:
                .error(message: UpdatesCopy.errorMessage())
            }
        }
    }
}
#endif
