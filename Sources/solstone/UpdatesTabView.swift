import SwiftUI

struct UpdatesTabView: View {
    @Bindable var controller: UpdateController

    #if DEBUG
    @State private var debugFixture: DebugFixture = .idle
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !controller.canCheckForUpdates {
                titleBlock(
                    title: UpdatesCopy.unavailableTitle,
                    subtitle: UpdatesCopy.unavailableSubtitle
                )
            } else {
                header
                transientBlock
                autoUpdateGroupBox
            }

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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(UpdatesCopy.appHeader(version: appVersion))
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(lastCheckedSubtitle())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            headerTrailing
        }
    }

    @ViewBuilder
    private var headerTrailing: some View {
        switch controller.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.6)
                Text(UpdatesCopy.checkingInline)
                    .foregroundStyle(.secondary)
                Button(UpdatesCopy.actionCancel, action: controller.cancel)
            }
        default:
            Button(
                controller.lastCheckedAt == nil ? UpdatesCopy.actionCheckNow : UpdatesCopy.actionCheckAgain,
                action: controller.checkForUpdates
            )
        }
    }

    @ViewBuilder
    private var transientBlock: some View {
        switch controller.state {
        case .idle, .noUpdateAvailable:
            EmptyView()
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

    private var autoUpdateGroupBox: some View {
        GroupBox(label: Text(UpdatesCopy.autoUpdateGroupTitle).font(.headline)) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(UpdatesCopy.autoCheckToggleLabel, isOn: $controller.automaticChecksEnabled)

                Picker(UpdatesCopy.frequencyPickerLabel, selection: frequencyBinding) {
                    ForEach(FrequencyOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(!controller.automaticChecksEnabled)

                Toggle(UpdatesCopy.autoDownloadToggleLabel, isOn: $controller.automaticDownloadsEnabled)
            }
            .padding(.vertical, 4)
        }
    }

    private var frequencyBinding: Binding<FrequencyOption> {
        Binding(
            get: { FrequencyOption.nearest(to: controller.updateCheckInterval) },
            set: { controller.updateCheckInterval = $0.seconds }
        )
    }

    private func lastCheckedSubtitle() -> String {
        guard let date = controller.lastCheckedAt else {
            return UpdatesCopy.lastCheckedNever
        }

        let relative = date.formatted(.relative(presentation: .named))

        switch controller.lastCheckResult {
        case .upToDate:
            return UpdatesCopy.lastCheckedUpToDate(relative: relative)
        case .updateFound(let version):
            return UpdatesCopy.lastCheckedUpdateFound(relative: relative, version: version)
        case .failed:
            return UpdatesCopy.lastCheckedFailed(relative: relative)
        case .none:
            return UpdatesCopy.lastCheckedGeneric(relative: relative)
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

private enum FrequencyOption: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .day:
            return 86_400
        case .week:
            return 604_800
        case .month:
            return 2_592_000
        }
    }

    var label: String {
        switch self {
        case .day:
            return UpdatesCopy.frequencyDay
        case .week:
            return UpdatesCopy.frequencyWeek
        case .month:
            return UpdatesCopy.frequencyMonth
        }
    }

    static func nearest(to interval: TimeInterval) -> FrequencyOption {
        guard interval > 0 else { return .week }
        return Self.allCases.min { abs($0.seconds - interval) < abs($1.seconds - interval) } ?? .week
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
