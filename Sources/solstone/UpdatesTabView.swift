import SwiftUI

struct UpdatesTabView: View {
    @Bindable var controller: UpdateController

    #if DEBUG
    @State private var debugFixture: DebugFixture = .idle
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AXStateCompanion(
                id: AXID.Updates.statusState,
                value: controller.state.axToken
            )
            if !controller.canCheckForUpdates {
                titleBlock(
                    title: UpdatesCopy.unavailableTitle,
                    subtitle: UpdatesCopy.unavailableSubtitle
                )
                .accessibilityIdentifier(AXID.Updates.unavailable)
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
            .accessibilityIdentifier(AXID.Updates.debugStatePicker)
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
                    .accessibilityIdentifier(AXID.Updates.cancel)
            }
        default:
            Button(
                controller.lastCheckedAt == nil ? UpdatesCopy.actionCheckNow : UpdatesCopy.actionCheckAgain,
                action: controller.checkForUpdates
            )
            .accessibilityIdentifier(AXID.Updates.check)
        }
    }

    @ViewBuilder
    private var transientBlock: some View {
        switch controller.state {
        case .idle, .noUpdateAvailable, .checking:
            EmptyView()
        case .updateAvailable(let version, let releaseNotes):
            titleBlock(
                title: UpdatesCopy.updateAvailableTitle(version: version),
                subtitle: UpdatesCopy.updateAvailableSubtitle(version: version)
            )
            releaseNotesSection(releaseNotes)
            actionRow(
                primaryTitle: UpdatesCopy.actionDownload,
                primaryAction: controller.install,
                primaryID: AXID.Updates.download,
                secondaryTitle: UpdatesCopy.actionDismiss,
                secondaryAction: controller.dismiss,
                secondaryID: AXID.Updates.dismiss
            )
        case .downloading(let version, let receivedBytes, let totalBytes):
            titleBlock(
                title: UpdatesCopy.downloadingTitle(version: version),
                subtitle: UpdatesCopy.downloadingSubtitle(receivedBytes: receivedBytes, totalBytes: totalBytes)
            )
            progressView(receivedBytes: receivedBytes, totalBytes: totalBytes)
            actionRow(
                primaryTitle: UpdatesCopy.actionCancel,
                primaryAction: controller.cancel,
                primaryID: AXID.Updates.cancel
            )
        case .extracting(let version, let progress):
            titleBlock(
                title: UpdatesCopy.extractingTitle(version: version),
                subtitle: UpdatesCopy.extractingSubtitle
            )
            ProgressView(value: min(max(0.9 + (progress * 0.1), 0.9), 1.0))
            AXStateCompanion(
                id: AXID.Updates.extractProgress,
                value: axPercentString(progress)
            )
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
                primaryID: AXID.Updates.install,
                secondaryTitle: UpdatesCopy.actionDismiss,
                secondaryAction: controller.dismiss,
                secondaryID: AXID.Updates.dismiss
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
                primaryID: AXID.Updates.retry,
                secondaryTitle: UpdatesCopy.actionDismiss,
                secondaryAction: controller.dismiss,
                secondaryID: AXID.Updates.dismiss
            )
        }
    }

    private var autoUpdateGroupBox: some View {
        GroupBox(label: Text(UpdatesCopy.autoUpdateGroupTitle).font(.headline)) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(UpdatesCopy.autoCheckToggleLabel, isOn: $controller.automaticChecksEnabled)
                    .accessibilityIdentifier(AXID.Updates.automaticChecks)

                Picker(UpdatesCopy.frequencyPickerLabel, selection: frequencyBinding) {
                    ForEach(FrequencyOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(!controller.automaticChecksEnabled)
                .accessibilityIdentifier(AXID.Updates.frequencyPicker)
                AXStateCompanion(
                    id: AXID.Updates.frequencyState,
                    value: frequencyBinding.wrappedValue.rawValue
                )

                Toggle(UpdatesCopy.autoDownloadToggleLabel, isOn: $controller.automaticDownloadsEnabled)
                    .accessibilityIdentifier(AXID.Updates.automaticDownloads)
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
            let model = ReleaseNotesViewModel(markdown: releaseNotes)
            VStack(alignment: .leading, spacing: 8) {
                Text(UpdatesCopy.releaseNotesTitle)
                    .font(.headline)

                if let blocks = model.blocks {
                    if model.wrapsInScrollView {
                        ScrollView {
                            blockList(blocks)
                        }
                        .frame(maxHeight: 280)
                    } else {
                        blockList(blocks)
                    }
                } else {
                    Text(releaseNotes)
                }

                Link(model.onlineLinkLabel, destination: model.onlineLinkURL)
                    .font(.callout)
                    .accessibilityIdentifier(AXID.Updates.releaseNotesOnline)
            }
            .accessibilityIdentifier(AXID.Updates.releaseNotes)
        }
    }

    @ViewBuilder
    private func blockList(_ blocks: [ReleaseNotesViewModel.Block]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                case .listItem(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(text)
                    }
                    .font(.subheadline)
                case .paragraph(let text):
                    Text(text)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private func progressView(receivedBytes: UInt64, totalBytes: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let totalBytes, totalBytes > 0 {
                ProgressView(value: Double(receivedBytes), total: Double(totalBytes))
            } else {
                ProgressView()
            }
            AXStateCompanion(
                id: AXID.Updates.downloadProgress,
                value: axDownloadPercentString(receivedBytes: receivedBytes, totalBytes: totalBytes)
            )
        }
    }

    @ViewBuilder
    private func actionRow(
        primaryTitle: String?,
        primaryAction: (() -> Void)?,
        primaryID: String? = nil,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        secondaryID: String? = nil
    ) -> some View {
        if primaryTitle != nil || secondaryTitle != nil {
            HStack {
                if let primaryTitle, let primaryAction {
                    actionButton(primaryTitle, id: primaryID, action: primaryAction)
                }

                if let secondaryTitle, let secondaryAction {
                    actionButton(secondaryTitle, id: secondaryID, action: secondaryAction)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ title: String, id: String?, action: @escaping () -> Void) -> some View {
        if let id {
            Button(title, action: action)
                .accessibilityIdentifier(id)
        } else {
            Button(title, action: action)
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

        private static let _debugReleaseNotes_1_3_0 = """
### Added
- you can now run sol's on-screen analysis entirely on your own Apple Silicon Mac. choose the on-device option in settings, and the part of sol that makes sense of what's on your screen runs locally, with nothing about those frames going to a cloud provider. it's opt-in, vision-only for now, and needs a Mac with at least 16 GB of memory. a one-time model download happens the first time you turn it on.
- the menu bar now tells you when sol's background pipeline has stopped and lets you restart it in place. if the pipeline goes quiet, you'll see "pipeline stopped" with a click-to-restart action, so you can recover without leaving the app.
- you can now power sol with your Anthropic or OpenAI account without installing anything separately. enable the provider in settings and paste your key, and solstone installs what it needs on its own.

### Changed
- the timeline view is rebuilt. it fits any window width, shows where each entry came from with a link to that day, and refreshes in place as new days roll up.
- long todo lists load faster. solstone now shows a focused first screen with a "show more" control, instead of rendering the entire list up front.
- pairing a phone is more reliable, and the paused state in the menu now reads "paused - 8 min left" so you can see at a glance when sol resumes.

### Fixed
- videos and audio in your journal that wouldn't play now play correctly, with a clearer message on the rare file that still can't.
- when transcription hit a dense stretch of speech it could fail outright; it now recovers on its own, and segments that did fail are surfaced instead of disappearing silently.
- pages occasionally got stuck loading on a cold start, and the paused and error menu-bar icons had lost their sun in 1.2.1. both are resolved, alongside internal stability improvements.
"""

        var sampleState: UpdateState {
            switch self {
            case .idle:
                .idle
            case .checking:
                .checking
            case .updateAvailable:
                .updateAvailable(version: "1.3.0", releaseNotes: Self._debugReleaseNotes_1_3_0)
            case .downloading:
                .downloading(version: "1.1.0", receivedBytes: 1_048_576, totalBytes: 4_194_304)
            case .extracting:
                .extracting(version: "1.1.0", progress: 0.5)
            case .readyToInstall:
                .readyToInstall(version: "1.3.0", releaseNotes: Self._debugReleaseNotes_1_3_0)
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
