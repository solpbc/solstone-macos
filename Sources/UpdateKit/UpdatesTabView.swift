import AppKit
import SolstoneCore
import SwiftUI

public struct UpdatesTabView: View {
    @Bindable private var controller: UpdateController
    private let copy: UpdatesCopy

    #if DEBUG
    @State private var debugFixture: DebugFixture = .idle
    #endif

    public init(controller: UpdateController, copy: UpdatesCopy) {
        self.controller = controller
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AXStateCompanion(
                id: UpdatesAXID.statusState,
                value: controller.statusAXToken
            )
            if !controller.canCheckForUpdates {
                titleBlock(
                    title: copy.unavailableTitle,
                    subtitle: copy.unavailableSubtitle
                )
                .accessibilityIdentifier(UpdatesAXID.unavailable)
            } else if let presentation = updatesNotRunningPresentation(
                liveness: controller.updatesPaneLiveness,
                copy: copy
            ) {
                notRunningBlock(presentation)
            } else {
                header
                transientBlock
                autoUpdateGroupBox
            }

            Spacer(minLength: 0)

            Divider()

            Text(copy.privacyFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)

            #if DEBUG
            Divider()

            Picker("debug state", selection: $debugFixture) {
                ForEach(DebugFixture.allCases) { fixture in
                    Text(fixture.rawValue).tag(fixture)
                }
            }
            .accessibilityIdentifier(UpdatesAXID.debugStatePicker)
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
                Text(copy.appHeader(version: appVersion))
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
                Text(copy.checkingInline)
                    .foregroundStyle(.secondary)
                Button(copy.actionCancel, action: controller.cancel)
                    .accessibilityIdentifier(UpdatesAXID.cancel)
            }
        default:
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Button(
                        controller.lastCheckedAt == nil ? copy.actionCheckNow : copy.actionCheckAgain,
                        action: controller.checkForUpdates
                    )
                    .disabled(!controller.canStartManualCheck)
                    .accessibilityIdentifier(UpdatesAXID.check)
                    AXStateCompanion(
                        id: UpdatesAXID.checkState,
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
                    title: copy.downloadingTitle(version: version),
                    subtitle: copy.downloadingSubtitle(receivedBytes: receivedBytes, totalBytes: totalBytes)
                )
                progressView(receivedBytes: receivedBytes, totalBytes: totalBytes)
                actionRow(
                    primaryTitle: copy.actionCancel,
                    primaryAction: controller.cancel,
                    primaryID: UpdatesAXID.cancel
                )
            }
        case .extracting:
            if case .extracting(let version, let progress) = controller.activity {
                titleBlock(
                    title: copy.extractingTitle(version: version),
                    subtitle: copy.extractingSubtitle
                )
                ProgressView(value: min(max(0.9 + (progress * 0.1), 0.9), 1.0))
                AXStateCompanion(
                    id: UpdatesAXID.extractProgress,
                    value: axPercentString(progress)
                )
                actionRow(primaryTitle: nil, primaryAction: nil)
            }
        case .readyToInstall:
            if case .readyToInstall(let version, let releaseNotes) = controller.activity {
                titleBlock(
                    title: copy.readyToInstallTitle(version: version),
                    subtitle: copy.readyToInstallSubtitle
                )
                releaseNotesSection(releaseNotes)
                actionRow(
                    primaryTitle: copy.actionInstall,
                    primaryAction: controller.install,
                    primaryID: UpdatesAXID.install,
                    secondaryTitle: copy.actionDismiss,
                    secondaryAction: controller.dismiss,
                    secondaryID: UpdatesAXID.dismiss
                )
            }
        case .installing:
            if case .installing(let version) = controller.activity {
                titleBlock(
                    title: copy.installingTitle(version: version),
                    subtitle: copy.installingSubtitle
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
    private func notRunningBlock(_ presentation: UpdatesNotRunningPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title)
                .font(.title3)
                .fontWeight(.semibold)
                .accessibilityIdentifier(UpdatesAXID.notRunning)

            Button(presentation.retryTitle) {
                controller.retryStartingUpdater()
            }
            .disabled(presentation.retryDisabled)
            .accessibilityIdentifier(UpdatesAXID.notRunningRetry)

            Text(presentation.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(UpdatesAXID.notRunningReason)
        }
    }

    @ViewBuilder
    private func backgroundDownloadBlock(_ phase: BackgroundDownloadPhase) -> some View {
        titleBlock(
            title: backgroundDownloadTitle(for: phase),
            subtitle: copy.backgroundDownloadSubtitle
        )
        ProgressView()
    }

    @ViewBuilder
    private func deferredBlock(version: String) -> some View {
        titleBlock(
            title: copy.deferredTitle(version: version),
            subtitle: copy.deferredSubtitle
        )
        AXStateCompanion(
            id: UpdatesAXID.deferredInstallState,
            value: "deferred"
        )
        actionRow(
            primaryTitle: copy.actionCheckAgain,
            primaryAction: controller.checkForUpdates,
            primaryID: UpdatesAXID.check,
            primaryDisabled: !controller.canCheckAgainFromDeferred
        )
        actionReasonText(isEnabled: controller.canCheckAgainFromDeferred)
        AXStateCompanion(
            id: UpdatesAXID.checkAgainState,
            value: axEnabledString(controller.canCheckAgainFromDeferred)
        )
    }

    @ViewBuilder
    private func stagedReadyBlock(_ update: AvailableUpdate) -> some View {
        titleBlock(
            title: copy.stagedReadyTitle(version: update.version),
            subtitle: copy.stagedReadySubtitle
        )
        releaseNotesSection(update.releaseNotes)
        actionRow(
            primaryTitle: copy.actionRelaunchToInstall,
            primaryAction: relaunchToInstallStagedUpdate,
            primaryID: UpdatesAXID.install,
            secondaryTitle: copy.actionDismiss,
            secondaryAction: controller.suppressStagedBlock,
            secondaryID: UpdatesAXID.dismissStaged
        )
    }

    @ViewBuilder
    private func failedBlock(availableVersion: String?) -> some View {
        titleBlock(
            title: copy.errorTitle,
            subtitle: failedSubtitle(availableVersion: availableVersion)
        )
        if controller.hasLiveUpdateReply {
            actionRow(
                primaryTitle: copy.actionRetry,
                primaryAction: controller.checkForUpdates,
                primaryID: UpdatesAXID.retry,
                primaryDisabled: !controller.canRetry,
                secondaryTitle: copy.actionDismiss,
                secondaryAction: controller.dismiss,
                secondaryID: UpdatesAXID.dismiss
            )
        } else {
            actionRow(
                primaryTitle: copy.actionRetry,
                primaryAction: controller.checkForUpdates,
                primaryID: UpdatesAXID.retry,
                primaryDisabled: !controller.canRetry
            )
        }
        actionReasonText(isEnabled: controller.canRetry)
        AXStateCompanion(
            id: UpdatesAXID.retryState,
            value: axEnabledString(controller.canRetry)
        )
    }

    @ViewBuilder
    private func availableBlock(_ update: AvailableUpdate) -> some View {
        titleBlock(
            title: copy.updateAvailableTitle(version: update.version),
            subtitle: copy.updateAvailableSubtitle(version: update.version)
        )
        releaseNotesSection(update.releaseNotes)
        if controller.hasLiveUpdateReply {
            actionRow(
                primaryTitle: copy.actionDownload,
                primaryAction: controller.download,
                primaryID: UpdatesAXID.download,
                primaryDisabled: !controller.canDownload,
                secondaryTitle: copy.actionDismiss,
                secondaryAction: controller.dismiss,
                secondaryID: UpdatesAXID.dismiss
            )
        } else {
            actionRow(
                primaryTitle: copy.actionDownload,
                primaryAction: controller.download,
                primaryID: UpdatesAXID.download,
                primaryDisabled: !controller.canDownload
            )
        }
        actionReasonText(isEnabled: controller.canDownload)
        AXStateCompanion(
            id: UpdatesAXID.downloadState,
            value: axEnabledString(controller.canDownload)
        )
    }

    private func failedSubtitle(availableVersion: String?) -> String {
        if let version = availableVersion {
            return copy.errorWithAvailableMessage(version: version)
        }

        return copy.errorMessage()
    }

    private func backgroundDownloadTitle(for phase: BackgroundDownloadPhase) -> String {
        switch phase {
        case .downloading(let version):
            return copy.backgroundDownloadingTitle(version: version)
        case .finishingUp(let version):
            return copy.backgroundFinishingTitle(version: version)
        }
    }

    @ViewBuilder
    private func actionReasonText(isEnabled: Bool, alignment: TextAlignment = .leading) -> some View {
        if let reason = updatesPaneReason(
            isEnabled: isEnabled,
            backgroundDownload: controller.backgroundDownload,
            liveness: controller.updatesPaneLiveness,
            copy: copy
        ) {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment)
        }
    }

    private var autoUpdateGroupBox: some View {
        GroupBox(label: Text(copy.autoUpdateGroupTitle).font(.headline)) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(copy.autoCheckToggleLabel, isOn: $controller.automaticChecksEnabled)
                    .accessibilityIdentifier(UpdatesAXID.automaticChecks)

                Picker(copy.frequencyPickerLabel, selection: frequencyBinding) {
                    ForEach(FrequencyOption.allCases) { option in
                        Text(option.label(copy: copy)).tag(option)
                    }
                }
                .disabled(!controller.automaticChecksEnabled)
                .accessibilityIdentifier(UpdatesAXID.frequencyPicker)
                AXStateCompanion(
                    id: UpdatesAXID.frequencyState,
                    value: frequencyBinding.wrappedValue.rawValue
                )

                Toggle(copy.autoDownloadToggleLabel, isOn: $controller.automaticDownloadsEnabled)
                    .accessibilityIdentifier(UpdatesAXID.automaticDownloads)
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
            return copy.lastCheckedNever
        }

        let relative = copy.lastCheckedRelative(checkedAt: date, now: now)

        switch controller.reconciledStatus.lastCheck?.outcome {
        case .upToDate:
            return copy.lastCheckedUpToDate(relative: relative)
        case .found:
            guard let version = controller.reconciledStatus.availableVersion else {
                return copy.lastCheckedGeneric(relative: relative)
            }
            return copy.lastCheckedUpdateFound(relative: relative, version: version)
        case .staged:
            guard let version = controller.reconciledStatus.availableVersion else {
                return copy.lastCheckedGeneric(relative: relative)
            }
            return copy.lastCheckedStaged(relative: relative, version: version)
        case .failed:
            return copy.lastCheckedFailed(relative: relative)
        case .none:
            return copy.lastCheckedGeneric(relative: relative)
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
            let model = ReleaseNotesViewModel(markdown: releaseNotes, copy: copy)
            VStack(alignment: .leading, spacing: 8) {
                Text(copy.releaseNotesTitle)
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
                    .accessibilityIdentifier(UpdatesAXID.releaseNotesOnline)
            }
            .accessibilityIdentifier(UpdatesAXID.releaseNotes)
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
                id: UpdatesAXID.downloadProgress,
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

public enum FrequencyOption: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .day:
            return 86_400
        case .week:
            return 604_800
        case .month:
            return 2_592_000
        }
    }

    public func label(copy: UpdatesCopy) -> String {
        switch self {
        case .day:
            return copy.frequencyDay
        case .week:
            return copy.frequencyWeek
        case .month:
            return copy.frequencyMonth
        }
    }

    public static func nearest(to interval: TimeInterval) -> FrequencyOption {
        guard interval > 0 else { return .week }
        return Self.allCases.min { abs($0.seconds - interval) < abs($1.seconds - interval) } ?? .week
    }
}

public enum UpdatesPaneBlock: Equatable {
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

public func updatesPaneBlock(
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

public struct UpdatesPaneLiveness: Equatable, Sendable {
    public var canCheckForUpdates: Bool
    public var updaterArmFailureReason: String?
    public var isRearmingUpdater: Bool
    public var sparkleSessionInProgress: Bool
    public var activity: UpdateActivity
    public var hasPendingChoiceReply: Bool
    public var hasPendingCancellation: Bool
    public var installFinalizationInFlight: Bool
    public var installFinalizationCommitted: Bool

    public init(
        canCheckForUpdates: Bool,
        updaterArmFailureReason: String?,
        isRearmingUpdater: Bool,
        sparkleSessionInProgress: Bool,
        activity: UpdateActivity,
        hasPendingChoiceReply: Bool,
        hasPendingCancellation: Bool,
        installFinalizationInFlight: Bool,
        installFinalizationCommitted: Bool
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.updaterArmFailureReason = updaterArmFailureReason
        self.isRearmingUpdater = isRearmingUpdater
        self.sparkleSessionInProgress = sparkleSessionInProgress
        self.activity = activity
        self.hasPendingChoiceReply = hasPendingChoiceReply
        self.hasPendingCancellation = hasPendingCancellation
        self.installFinalizationInFlight = installFinalizationInFlight
        self.installFinalizationCommitted = installFinalizationCommitted
    }

    public var hasLiveSparkleSessionOrReply: Bool {
        sparkleSessionInProgress
            || activity != .idle
            || hasPendingChoiceReply
            || hasPendingCancellation
            || installFinalizationInFlight
            || installFinalizationCommitted
    }

    public var canDriveManualCheck: Bool {
        canCheckForUpdates && updaterArmFailureReason == nil && !hasLiveSparkleSessionOrReply
    }
}

public struct UpdatesNotRunningPresentation: Equatable, Sendable {
    public let title: String
    public let retryTitle: String
    public let retryDisabled: Bool
    public let reason: String
}

public func updatesNotRunningPresentation(
    liveness: UpdatesPaneLiveness,
    copy: UpdatesCopy
) -> UpdatesNotRunningPresentation? {
    guard liveness.canCheckForUpdates,
          let reason = liveness.updaterArmFailureReason
    else {
        return nil
    }

    return UpdatesNotRunningPresentation(
        title: copy.updateChecksNotRunningTitle,
        retryTitle: liveness.isRearmingUpdater ? copy.actionRetrying : copy.actionRetry,
        retryDisabled: liveness.isRearmingUpdater,
        reason: reason
    )
}

public func updatesPaneReason(
    isEnabled: Bool,
    backgroundDownload: BackgroundDownloadPhase?,
    liveness: UpdatesPaneLiveness,
    copy: UpdatesCopy
) -> String? {
    guard !isEnabled else { return nil }
    guard liveness.canCheckForUpdates else { return copy.actionReasonUpdatesUnavailable }
    if let reason = liveness.updaterArmFailureReason {
        return reason
    }

    switch backgroundDownload {
    case .downloading:
        return copy.actionReasonDownloadInProgress
    case .finishingUp:
        return copy.actionReasonDownloadFinishing
    case .none:
        break
    }

    if liveness.installFinalizationInFlight || liveness.installFinalizationCommitted {
        return copy.actionReasonInstallHandoff
    }

    if liveness.hasPendingChoiceReply {
        return copy.actionReasonUpdateChoicePending
    }

    return copy.actionReasonUpdateInProgress
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
