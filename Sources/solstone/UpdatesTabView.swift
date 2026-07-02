import AppKit
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
                value: controller.statusAXToken
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
                fixture.apply(to: controller)
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

                // TimelineView only updates when visible, avoiding background timer
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    Text(lastCheckedSubtitle(now: context.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            headerTrailing
        }
    }

    @ViewBuilder
    private var headerTrailing: some View {
        switch controller.activity {
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
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Button(
                        controller.lastCheckedAt == nil ? UpdatesCopy.actionCheckNow : UpdatesCopy.actionCheckAgain,
                        action: controller.checkForUpdates
                    )
                    .disabled(!controller.canStartManualCheck)
                    .accessibilityIdentifier(AXID.Updates.check)
                    AXStateCompanion(
                        id: AXID.Updates.checkState,
                        value: axEnabledString(controller.canStartManualCheck)
                    )
                }
                actionReasonText(isEnabled: controller.canStartManualCheck, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var transientBlock: some View {
        let status = controller.durableUpdateStatus
        switch updatesPaneBlock(
            status: status,
            activity: controller.activity,
            backgroundDownload: controller.backgroundDownload,
            stagedBlockSuppressed: controller.stagedBlockSuppressed
        ) {
        case .checking:
            EmptyView()
        case .downloading:
            if case .downloading(let version, let receivedBytes, let totalBytes) = controller.activity {
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
            }
        case .extracting:
            if case .extracting(let version, let progress) = controller.activity {
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
            }
        case .readyToInstall:
            if case .readyToInstall(let version, let releaseNotes) = controller.activity {
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
            }
        case .installing:
            if case .installing(let version) = controller.activity {
                titleBlock(
                    title: UpdatesCopy.installingTitle(version: version),
                    subtitle: UpdatesCopy.installingSubtitle
                )
                ProgressView()
            }
        case .backgroundDownloading:
            if let backgroundDownload = controller.backgroundDownload {
                backgroundDownloadBlock(backgroundDownload)
            }
        case .deferred:
            if case .deferred(let version) = status {
                deferredBlock(version: version)
            }
        case .stagedReady:
            if case .staged(let version, let releaseNotes) = status {
                stagedReadyBlock(AvailableUpdate(version: version, releaseNotes: releaseNotes))
            }
        case .failed:
            if case .failedWithAvailable(let version) = status {
                failedBlock(availableVersion: version)
            } else {
                failedBlock(availableVersion: nil)
            }
        case .available:
            if case .available(let version, let releaseNotes) = status {
                availableBlock(AvailableUpdate(version: version, releaseNotes: releaseNotes))
            }
        case .empty:
            EmptyView()
        }
    }

    @ViewBuilder
    private func backgroundDownloadBlock(_ phase: BackgroundDownloadPhase) -> some View {
        titleBlock(
            title: backgroundDownloadTitle(for: phase),
            subtitle: UpdatesCopy.backgroundDownloadSubtitle
        )
        ProgressView()
    }

    @ViewBuilder
    private func deferredBlock(version: String) -> some View {
        titleBlock(
            title: UpdatesCopy.deferredTitle(version: version),
            subtitle: UpdatesCopy.deferredSubtitle
        )
        AXStateCompanion(
            id: AXID.Updates.deferredInstallState,
            value: "deferred"
        )
        actionRow(
            primaryTitle: UpdatesCopy.actionCheckAgain,
            primaryAction: controller.checkForUpdates,
            primaryID: AXID.Updates.check,
            primaryDisabled: !controller.canCheckAgainFromDeferred
        )
        actionReasonText(isEnabled: controller.canCheckAgainFromDeferred)
        AXStateCompanion(
            id: AXID.Updates.checkAgainState,
            value: axEnabledString(controller.canCheckAgainFromDeferred)
        )
    }

    @ViewBuilder
    private func stagedReadyBlock(_ update: AvailableUpdate) -> some View {
        titleBlock(
            title: UpdatesCopy.stagedReadyTitle(version: update.version),
            subtitle: UpdatesCopy.stagedReadySubtitle
        )
        releaseNotesSection(update.releaseNotes)
        actionRow(
            primaryTitle: UpdatesCopy.actionRelaunchToInstall,
            primaryAction: relaunchToInstallStagedUpdate,
            primaryID: AXID.Updates.install,
            secondaryTitle: UpdatesCopy.actionDismiss,
            secondaryAction: controller.suppressStagedBlock,
            secondaryID: AXID.Updates.dismissStaged
        )
    }

    @ViewBuilder
    private func failedBlock(availableVersion: String?) -> some View {
        titleBlock(
            title: UpdatesCopy.errorTitle,
            subtitle: failedSubtitle(availableVersion: availableVersion)
        )
        if controller.hasLiveUpdateReply {
            actionRow(
                primaryTitle: UpdatesCopy.actionRetry,
                primaryAction: controller.checkForUpdates,
                primaryID: AXID.Updates.retry,
                primaryDisabled: !controller.canRetry,
                secondaryTitle: UpdatesCopy.actionDismiss,
                secondaryAction: controller.dismiss,
                secondaryID: AXID.Updates.dismiss
            )
        } else {
            actionRow(
                primaryTitle: UpdatesCopy.actionRetry,
                primaryAction: controller.checkForUpdates,
                primaryID: AXID.Updates.retry,
                primaryDisabled: !controller.canRetry
            )
        }
        actionReasonText(isEnabled: controller.canRetry)
        AXStateCompanion(
            id: AXID.Updates.retryState,
            value: axEnabledString(controller.canRetry)
        )
    }

    @ViewBuilder
    private func availableBlock(_ update: AvailableUpdate) -> some View {
        titleBlock(
            title: UpdatesCopy.updateAvailableTitle(version: update.version),
            subtitle: UpdatesCopy.updateAvailableSubtitle(version: update.version)
        )
        releaseNotesSection(update.releaseNotes)
        if controller.hasLiveUpdateReply {
            actionRow(
                primaryTitle: UpdatesCopy.actionDownload,
                primaryAction: controller.download,
                primaryID: AXID.Updates.download,
                primaryDisabled: !controller.canDownload,
                secondaryTitle: UpdatesCopy.actionDismiss,
                secondaryAction: controller.dismiss,
                secondaryID: AXID.Updates.dismiss
            )
        } else {
            actionRow(
                primaryTitle: UpdatesCopy.actionDownload,
                primaryAction: controller.download,
                primaryID: AXID.Updates.download,
                primaryDisabled: !controller.canDownload
            )
        }
        actionReasonText(isEnabled: controller.canDownload)
        AXStateCompanion(
            id: AXID.Updates.downloadState,
            value: axEnabledString(controller.canDownload)
        )
    }

    private func failedSubtitle(availableVersion: String?) -> String {
        if let version = availableVersion {
            return UpdatesCopy.errorWithAvailableMessage(version: version)
        }

        return UpdatesCopy.errorMessage()
    }

    private func backgroundDownloadTitle(for phase: BackgroundDownloadPhase) -> String {
        switch phase {
        case .downloading(let version):
            return UpdatesCopy.backgroundDownloadingTitle(version: version)
        case .finishingUp(let version):
            return UpdatesCopy.backgroundFinishingTitle(version: version)
        }
    }

    @ViewBuilder
    private func actionReasonText(isEnabled: Bool, alignment: TextAlignment = .leading) -> some View {
        if let reason = updatesPaneReason(
            isEnabled: isEnabled,
            backgroundDownload: controller.backgroundDownload,
            liveness: controller.updatesPaneLiveness
        ) {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment)
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

    private func lastCheckedSubtitle(now: Date) -> String {
        guard let date = controller.lastCheckedAt else {
            return UpdatesCopy.lastCheckedNever
        }

        let relative = UpdatesCopy.lastCheckedRelative(checkedAt: date, now: now)

        switch controller.reconciledStatus.lastCheck?.outcome {
        case .upToDate:
            return UpdatesCopy.lastCheckedUpToDate(relative: relative)
        case .found:
            guard let version = controller.reconciledStatus.availableVersion else {
                return UpdatesCopy.lastCheckedGeneric(relative: relative)
            }
            return UpdatesCopy.lastCheckedUpdateFound(relative: relative, version: version)
        case .staged:
            guard let version = controller.reconciledStatus.availableVersion else {
                return UpdatesCopy.lastCheckedGeneric(relative: relative)
            }
            return UpdatesCopy.lastCheckedStaged(relative: relative, version: version)
        case .failed:
            return UpdatesCopy.lastCheckedFailed(relative: relative)
        case .none:
            return UpdatesCopy.lastCheckedGeneric(relative: relative)
        }
    }

    private func relaunchToInstallStagedUpdate() {
        controller.installStagedUpdate()
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
        primaryDisabled: Bool = false,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        secondaryID: String? = nil
    ) -> some View {
        if primaryTitle != nil || secondaryTitle != nil {
            HStack {
                if let primaryTitle, let primaryAction {
                    actionButton(primaryTitle, id: primaryID, disabled: primaryDisabled, action: primaryAction)
                }

                if let secondaryTitle, let secondaryAction {
                    actionButton(secondaryTitle, id: secondaryID, action: secondaryAction)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        id: String?,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        if let id {
            Button(title, action: action)
                .disabled(disabled)
                .accessibilityIdentifier(id)
        } else {
            Button(title, action: action)
                .disabled(disabled)
        }
    }
}

enum FrequencyOption: String, CaseIterable, Identifiable {
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

enum UpdatesPaneBlock: Equatable {
    case checking
    case downloading
    case extracting
    case readyToInstall
    case installing
    case backgroundDownloading
    case deferred
    case stagedReady
    case failed
    case available
    case empty
}

func updatesPaneBlock(
    status: DurableUpdateStatus,
    activity: UpdateActivity,
    backgroundDownload: BackgroundDownloadPhase?,
    stagedBlockSuppressed: Bool
) -> UpdatesPaneBlock {
    switch activity {
    case .idle:
        break
    case .checking:
        return .checking
    case .downloading:
        return .downloading
    case .extracting:
        return .extracting
    case .readyToInstall:
        return .readyToInstall
    case .installing:
        return .installing
    }

    if backgroundDownload != nil {
        return .backgroundDownloading
    }

    switch status {
    case .deferred:
        return .deferred
    case .staged:
        return stagedBlockSuppressed ? .empty : .stagedReady
    case .failedWithAvailable, .failed:
        return .failed
    case .available:
        return .available
    case .upToDate, .idle:
        return .empty
    }
}

struct UpdatesPaneLiveness: Equatable, Sendable {
    var canCheckForUpdates: Bool
    var sparkleSessionInProgress: Bool
    var activity: UpdateActivity
    var hasPendingChoiceReply: Bool
    var hasPendingCancellation: Bool
    var installFinalizationInFlight: Bool
    var installFinalizationCommitted: Bool

    var hasLiveSparkleSessionOrReply: Bool {
        sparkleSessionInProgress
            || activity != .idle
            || hasPendingChoiceReply
            || hasPendingCancellation
            || installFinalizationInFlight
            || installFinalizationCommitted
    }

    var canDriveManualCheck: Bool {
        canCheckForUpdates && !hasLiveSparkleSessionOrReply
    }
}

func updatesPaneReason(
    isEnabled: Bool,
    backgroundDownload: BackgroundDownloadPhase?,
    liveness: UpdatesPaneLiveness
) -> String? {
    guard !isEnabled else { return nil }
    guard liveness.canCheckForUpdates else { return UpdatesCopy.actionReasonUpdatesUnavailable }

    switch backgroundDownload {
    case .downloading:
        return UpdatesCopy.actionReasonDownloadInProgress
    case .finishingUp:
        return UpdatesCopy.actionReasonDownloadFinishing
    case .none:
        break
    }

    if liveness.installFinalizationInFlight || liveness.installFinalizationCommitted {
        return UpdatesCopy.actionReasonInstallHandoff
    }

    if liveness.hasPendingChoiceReply {
        return UpdatesCopy.actionReasonUpdateChoicePending
    }

    return UpdatesCopy.actionReasonUpdateInProgress
}

#if DEBUG
private extension UpdatesTabView {
    enum DebugFixture: String, CaseIterable, Identifiable {
        case idle
        case checking
        case updateAvailable
        case downloading
        case backgroundDownloading
        case backgroundFinishingUp
        case extracting
        case readyToInstall
        case installing
        case upToDate
        case error

        var id: String { rawValue }

        private static let _debugReleaseNotes_1_3_0 = """
### Added
- you can now run sol's on-screen analysis entirely on your own Apple Silicon Mac. choose the on-device option in settings, and the part of sol that makes sense of what's on your screen runs locally, with nothing about those frames going to a cloud provider. it's opt-in, vision-only for now, and needs a Mac with at least 16 GB of memory. a one-time model download happens the first time you turn it on.
- the menu bar now tells you when your journal needs attention and opens settings for restart or setup.
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

        @MainActor
        func apply(to controller: UpdateController) {
            let now = Date()
            switch self {
            case .idle:
                controller.applyDebugFixture(activity: .idle)
            case .checking:
                controller.applyDebugFixture(activity: .checking)
            case .updateAvailable:
                controller.applyDebugFixture(
                    activity: .idle,
                    availableUpdate: AvailableUpdate(version: "1.3.0", releaseNotes: Self._debugReleaseNotes_1_3_0),
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found),
                    hasLiveChoiceReply: true
                )
            case .downloading:
                controller.applyDebugFixture(
                    activity: .downloading(version: "1.1.0", receivedBytes: 1_048_576, totalBytes: 4_194_304),
                    availableUpdate: AvailableUpdate(version: "1.1.0", releaseNotes: nil),
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
                )
            case .backgroundDownloading:
                controller.applyDebugFixture(
                    activity: .idle,
                    availableUpdate: AvailableUpdate(version: "1.3.0", releaseNotes: Self._debugReleaseNotes_1_3_0),
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found),
                    backgroundDownload: .downloading(version: "1.3.0")
                )
            case .backgroundFinishingUp:
                controller.applyDebugFixture(
                    activity: .idle,
                    availableUpdate: AvailableUpdate(version: "1.3.0", releaseNotes: Self._debugReleaseNotes_1_3_0),
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found),
                    backgroundDownload: .finishingUp(version: "1.3.0")
                )
            case .extracting:
                controller.applyDebugFixture(
                    activity: .extracting(version: "1.1.0", progress: 0.5),
                    availableUpdate: AvailableUpdate(version: "1.1.0", releaseNotes: nil),
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
                )
            case .readyToInstall:
                controller.applyDebugFixture(
                    activity: .readyToInstall(version: "1.3.0", releaseNotes: Self._debugReleaseNotes_1_3_0),
                    availableUpdate: AvailableUpdate(version: "1.3.0", releaseNotes: Self._debugReleaseNotes_1_3_0),
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found),
                    hasLiveChoiceReply: true
                )
            case .installing:
                controller.applyDebugFixture(
                    activity: .installing(version: "1.1.0"),
                    availableUpdate: AvailableUpdate(version: "1.1.0", releaseNotes: nil),
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
                )
            case .upToDate:
                controller.applyDebugFixture(
                    activity: .idle,
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .upToDate)
                )
            case .error:
                controller.applyDebugFixture(
                    activity: .idle,
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .failed)
                )
            }
        }
    }
}
#endif
