import Foundation
import Observation
import SolstoneCore
import Sparkle
import os

@MainActor
protocol SparkleUpdating: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    func checkForUpdates()
    var sessionInProgress: Bool { get }
    func start() throws
}

extension SPUUpdater: SparkleUpdating {}

@MainActor
@Observable
final class UpdateController {
    typealias UpdaterFactory = @MainActor (SparkleUserDriver, any SPUUpdaterDelegate) -> (any SparkleUpdating)?
    typealias ExclusivityProvider = @MainActor () -> Bool
    typealias SessionLivenessProvider = @MainActor () -> Bool
    typealias PreInstallFinalizer = @MainActor () async -> Void
    typealias InstallFailureRecovery = @MainActor () async -> Void
    typealias PostInstallRecoveryScheduler = @MainActor (@escaping @MainActor () -> Void) -> Void
    typealias RunningVersionProvider = @MainActor () -> String

    private static let statusKey = "solstone.updates.status"
    private static let feedURLOverrideKey = "solstone.updates.feedURLOverride"
    private static let legacyLastCheckedAtKey = "solstone.updates.lastCheckedAt"
    private static let legacyLastCheckResultKey = "solstone.updates.lastCheckResult"

    private(set) var activity: UpdateActivity = .idle
    private(set) var reconciledStatus: ReconciledUpdateStatus
    private(set) var availableUpdate: AvailableUpdate?
    private(set) var deferredInstallIntent: DeferredInstallIntent?
    private(set) var exclusiveOperationInProgress = false

    private(set) var canCheckForUpdates: Bool

    private let updaterFactory: UpdaterFactory
    private let userDriver: SparkleUserDriver
    private let updaterDelegate: SparkleUpdaterDelegateAdapter
    private let exclusivityProvider: ExclusivityProvider?
    private let sessionLivenessProvider: SessionLivenessProvider?
    private let preInstallFinalizer: PreInstallFinalizer?
    private let installFailureRecovery: InstallFailureRecovery?
    private let postInstallRecoveryScheduler: PostInstallRecoveryScheduler
    private let defaults: UserDefaults

    private var updater: (any SparkleUpdating)?
    private var updaterStarted = false
    private var pendingChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var pendingReplyRequiresFinalization = false
    private var pendingCancellation: (() -> Void)?
    private var expectedContentLength: UInt64?
    private var blockedAutomaticCheckDuringExclusive = false
    // Sparkle handoff flags; distinct from AppQuitCoordinator's app committed-exit state.
    private var installFinalizationInFlight = false
    private var installFinalizationCommitted = false
    private var immediateStagedInstallHandler: (() -> Void)?
    private var pendingDownloadIntent = false

    internal var onExclusivityReevaluated: ((Bool) -> Void)?
    #if DEBUG
    internal var checkForUpdatesInterceptor: (() -> Void)?
    #endif

    var automaticChecksEnabled: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set {
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    var updateCheckInterval: TimeInterval {
        get { updater?.updateCheckInterval ?? 86_400 }
        set {
            updater?.updateCheckInterval = newValue
        }
    }

    var automaticDownloadsEnabled: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set {
            updater?.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastCheckedAt: Date? {
        reconciledStatus.lastCheck?.checkedAt
    }

    var hasLiveUpdateReply: Bool {
        pendingChoiceReply != nil
    }

    var canActOnAvailableUpdateDirectly: Bool {
        activity == .idle && pendingChoiceReply != nil && availableUpdate != nil
    }

    static var hasValidSparkleConfig: Bool {
        let info = Bundle.main.infoDictionary
        return validateSparkleConfig(
            feedURL: info?["SUFeedURL"] as? String,
            publicKey: info?["SUPublicEDKey"] as? String
        )
    }

    static func validateSparkleConfig(feedURL: String?, publicKey: String?) -> Bool {
        guard
            let feedURL,
            let publicKey,
            URL(string: feedURL) != nil,
            let keyData = Data(base64Encoded: publicKey),
            keyData.count == 32
        else {
            return false
        }

        return true
    }

    static func feedURLOverride(from defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: feedURLOverrideKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme == "https"
        else {
            return nil
        }
        return trimmed
    }

    init(
        feedURL: String? = nil,
        publicKey: String? = nil,
        runningVersion: @escaping RunningVersionProvider = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        },
        exclusivity: ExclusivityProvider? = nil,
        sessionInProgress: SessionLivenessProvider? = nil,
        preInstallFinalizer: PreInstallFinalizer? = nil,
        installFailureRecovery: InstallFailureRecovery? = nil,
        postInstallRecoveryScheduler: PostInstallRecoveryScheduler? = nil,
        defaults: UserDefaults = .standard,
        updaterFactory: @escaping UpdaterFactory
    ) {
        let info = Bundle.main.infoDictionary
        self.updaterFactory = updaterFactory
        self.userDriver = SparkleUserDriver()
        self.updaterDelegate = SparkleUpdaterDelegateAdapter()
        self.exclusivityProvider = exclusivity
        self.sessionLivenessProvider = sessionInProgress
        self.preInstallFinalizer = preInstallFinalizer
        self.installFailureRecovery = installFailureRecovery
        self.postInstallRecoveryScheduler = postInstallRecoveryScheduler ?? Self.defaultPostInstallRecoveryScheduler
        self.defaults = defaults
        self.canCheckForUpdates = Self.validateSparkleConfig(
            feedURL: feedURL ?? info?["SUFeedURL"] as? String,
            publicKey: publicKey ?? info?["SUPublicEDKey"] as? String
        )

        let loaded = Self.loadPersistedStatus(from: defaults)
        let reconciled = Self.reconcilePersistedStatus(loaded.status, runningVersion: runningVersion())
        self.reconciledStatus = reconciled.status
        self.availableUpdate = reconciled.status.availableVersion.map {
            AvailableUpdate(version: $0, releaseNotes: nil)
        }

        self.userDriver.attach(to: self)
        self.updaterDelegate.attach(to: self)

        if loaded.migrated || reconciled.changed {
            persistStatus()
            Self.removeLegacyStatusKeys(from: defaults)
        }

        if canCheckForUpdates {
            _ = ensureUpdaterStarted()
        } else {
            Logger.setup.warning("Sparkle disabled: missing or invalid SUFeedURL / SUPublicEDKey")
        }

        observeExclusivity()
    }

    convenience init(
        exclusivity: ExclusivityProvider? = nil,
        preInstallFinalizer: PreInstallFinalizer? = nil,
        installFailureRecovery: InstallFailureRecovery? = nil,
        postInstallRecoveryScheduler: PostInstallRecoveryScheduler? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            exclusivity: exclusivity,
            preInstallFinalizer: preInstallFinalizer,
            installFailureRecovery: installFailureRecovery,
            postInstallRecoveryScheduler: postInstallRecoveryScheduler,
            defaults: defaults
        ) { userDriver, delegate in
            SPUUpdater(
                hostBundle: .main,
                applicationBundle: .main,
                userDriver: userDriver,
                delegate: delegate
            )
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else {
            Logger.setup.warning("checkForUpdates() ignored because Sparkle config gate failed")
            return
        }

        guard !hasLiveSparkleSessionOrReply else {
            Logger.setup.info("checkForUpdates() ignored because a Sparkle update session is already active")
            return
        }

        #if DEBUG
        if let checkForUpdatesInterceptor {
            checkForUpdatesInterceptor()
            beginUserInitiatedCheck(cancellation: {})
            return
        }
        #endif

        guard ensureUpdaterStarted(), let updater else {
            Logger.setup.error("checkForUpdates() ignored because Sparkle updater failed to start")
            activity = .idle
            recordFailedCheck()
            return
        }

        updater.checkForUpdates()
    }

    func cancel() {
        guard !installFinalizationInFlight else { return }

        pendingDownloadIntent = false
        pendingCancellation?()
        clearPendingInteractions()
        activity = .idle
        deferredInstallIntent = nil
        recoverCommittedInstallFinalization()
    }

    func download() {
        if canActOnAvailableUpdateDirectly {
            install()
            return
        }

        guard !hasLiveSparkleSessionOrReply else {
            Logger.setup.info("download() ignored because a Sparkle update session is already active")
            return
        }

        pendingDownloadIntent = true
        checkForUpdates()
    }

    func install() {
        guard !installFinalizationInFlight else { return }

        if exclusiveOperationInProgress {
            let version = currentUpdateVersionForIntent()
            deferredInstallIntent = DeferredInstallIntent(version: version, requestedAt: Date())
            activity = .idle
            return
        }

        guard let reply = pendingChoiceReply else { return }
        let requiresFinalization = pendingReplyRequiresFinalization
        pendingChoiceReply = nil
        pendingReplyRequiresFinalization = false
        fireInstallReply(reply, requiresFinalization: requiresFinalization)
    }

    func dismiss() {
        guard !installFinalizationInFlight else { return }

        pendingDownloadIntent = false
        pendingChoiceReply?(.dismiss)
        clearPendingInteractions()
        deferredInstallIntent = nil
        activity = .idle
        recoverCommittedInstallFinalization()
    }

    func shouldAllowSparkleUpdateCheck(_ updateCheck: SPUUpdateCheck) -> Bool {
        guard exclusiveOperationInProgress else { return true }

        switch updateCheck {
        case .updates:
            return true
        case .updatesInBackground, .updateInformation:
            blockedAutomaticCheckDuringExclusive = true
            return false
        @unknown default:
            blockedAutomaticCheckDuringExclusive = true
            return false
        }
    }

    func sparkleFeedURLOverride() -> String? {
        Self.feedURLOverride(from: defaults)
    }

    func beginUserInitiatedCheck(cancellation: @escaping () -> Void) {
        stashCancellation(cancellation)
        activity = .checking
    }

    func presentUpdateFound(
        version: String,
        releaseNotes: String?,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let requiresFinalization: Bool
        let nextActivity: UpdateActivity
        switch state.stage {
        case .notDownloaded:
            requiresFinalization = false
            nextActivity = .idle
        case .downloaded, .installing:
            requiresFinalization = true
            nextActivity = .readyToInstall(version: version, releaseNotes: releaseNotes)
        @unknown default:
            requiresFinalization = true
            nextActivity = .readyToInstall(version: version, releaseNotes: releaseNotes)
        }
        stashChoiceReply(reply, requiresFinalization: requiresFinalization)
        activity = nextActivity

        if pendingDownloadIntent {
            pendingDownloadIntent = false
            install()
        }
    }

    func updateReleaseNotes(_ releaseNotes: String?) {
        guard var update = availableUpdate else { return }

        update.releaseNotes = releaseNotes
        availableUpdate = update

        switch activity {
        case .readyToInstall(let version, _):
            activity = .readyToInstall(version: version, releaseNotes: releaseNotes)
        default:
            break
        }
    }

    func presentNoUpdateFound() {
        pendingDownloadIntent = false
        clearPendingInteractions()
        activity = .idle
        deferredInstallIntent = nil
    }

    func presentUpdaterError(_ error: Error) {
        recoverCommittedInstallFinalization()
        Logger.setup.error("Sparkle error: \(String(describing: error), privacy: .public)")
        clearPendingInteractions()
        pendingDownloadIntent = false
        activity = .idle
    }

    func recordImmediateStagedInstallHandler(_ handler: @escaping () -> Void) {
        immediateStagedInstallHandler = handler
    }

    func installStagedUpdate() {
        guard updateIsStaged else { return }
        guard !installFinalizationInFlight, !installFinalizationCommitted else { return }

        guard let immediateInstallHandler = immediateStagedInstallHandler else {
            resumeStagedInstall()
            return
        }

        installFinalizationInFlight = true

        Task { @MainActor in
            await preInstallFinalizer?()
            installFinalizationCommitted = true
            immediateInstallHandler()
            postInstallRecoveryScheduler { [weak self] in
                guard let self, self.installFinalizationCommitted else { return }
                Logger.setup.warning("Sparkle staged install handoff did not terminate within 5 seconds; recovering update finalization")
                self.recoverCommittedInstallFinalization()
            }
            installFinalizationInFlight = false
        }
    }

    func beginDownload(cancellation: @escaping () -> Void) {
        stashCancellation(cancellation)
        expectedContentLength = nil
        activity = .downloading(version: availableUpdate?.version ?? "", receivedBytes: 0, totalBytes: nil)
    }

    func recordExpectedContentLength(_ length: UInt64) {
        expectedContentLength = length

        if case .downloading(let version, let receivedBytes, _) = activity {
            activity = .downloading(version: version, receivedBytes: receivedBytes, totalBytes: length)
        }
    }

    func appendDownloadedBytes(_ length: UInt64) {
        let version = availableUpdate?.version ?? ""

        switch activity {
        case .downloading(_, let receivedBytes, let totalBytes):
            activity = .downloading(version: version, receivedBytes: receivedBytes + length, totalBytes: totalBytes)
        default:
            activity = .downloading(version: version, receivedBytes: length, totalBytes: expectedContentLength)
        }
    }

    func beginExtracting() {
        clearPendingCancellation()
        activity = .extracting(version: availableUpdate?.version ?? "", progress: 0)
    }

    func updateExtractionProgress(_ progress: Double) {
        activity = .extracting(version: availableUpdate?.version ?? "", progress: progress)
    }

    func readyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        stashChoiceReply(reply, requiresFinalization: true)
        activity = .readyToInstall(
            version: availableUpdate?.version ?? "",
            releaseNotes: availableUpdate?.releaseNotes
        )
    }

    func installingUpdate() {
        clearPendingCancellation()
        activity = .installing(version: availableUpdate?.version ?? "")
    }

    func updateInstalledAndRelaunched() {
        installFinalizationCommitted = false
        clearPendingInteractions()
        deferredInstallIntent = nil
        activity = .idle
    }

    func dismissUpdateInstallation() {
        installFinalizationCommitted = false
        clearPendingInteractions()
        deferredInstallIntent = nil
        activity = .idle
    }

    var updateIsAvailable: Bool {
        availableUpdate != nil
    }

    var updateCheckFailed: Bool {
        reconciledStatus.lastCheck?.outcome == .failed
    }

    var updateIsStaged: Bool {
        reconciledStatus.lastCheck?.outcome == .staged && availableUpdate != nil
    }

    var stagedVersion: String? {
        updateIsStaged ? availableUpdate?.version : nil
    }

    var updatesNeedAttention: Bool {
        updateIsAvailable || updateCheckFailed || deferredInstallIntent != nil
    }

    var updatesAreCurrent: Bool {
        !updateIsAvailable && reconciledStatus.lastCheck?.outcome == .upToDate
    }

    private var canDriveManualCheck: Bool {
        canCheckForUpdates && !hasLiveSparkleSessionOrReply
    }

    var canStartManualCheck: Bool {
        canDriveManualCheck && !updateIsStaged
    }

    var canRetry: Bool {
        canDriveManualCheck
    }

    var canCheckAgainFromDeferred: Bool {
        canDriveManualCheck
    }

    var canDownload: Bool {
        canActOnAvailableUpdateDirectly || canDriveManualCheck
    }

    var durableUpdateStatus: DurableUpdateStatus {
        if let deferredInstallIntent {
            return .deferred(version: deferredInstallIntent.version)
        }

        if updateIsStaged, let update = availableUpdate {
            return .staged(version: update.version, releaseNotes: update.releaseNotes)
        }

        if updateCheckFailed {
            if let version = availableUpdate?.version {
                return .failedWithAvailable(version: version)
            }
            return .failed
        }

        if let update = availableUpdate {
            return .available(version: update.version, releaseNotes: update.releaseNotes)
        }

        if updatesAreCurrent {
            return .upToDate
        }

        return .idle
    }

    var statusAXToken: String {
        switch activity {
        case .idle:
            switch durableUpdateStatus {
            case .deferred:
                return "deferred_install"
            case .staged:
                return "staged_ready"
            case .failedWithAvailable, .failed:
                return "error"
            case .available:
                return "update_available"
            case .upToDate:
                return "up_to_date"
            case .idle:
                return "idle"
            }
        default:
            return activity.axToken
        }
    }

    #if DEBUG
    func applyDebugFixture(
        activity: UpdateActivity,
        availableUpdate: AvailableUpdate? = nil,
        lastCheck: ReconciledUpdateStatus.LastCheck? = nil,
        deferredInstallIntent: DeferredInstallIntent? = nil,
        hasLiveChoiceReply: Bool = false,
        choiceReply: ((SPUUserUpdateChoice) -> Void)? = nil
    ) {
        self.activity = activity
        self.availableUpdate = availableUpdate
        self.deferredInstallIntent = deferredInstallIntent
        self.reconciledStatus = ReconciledUpdateStatus(
            availableVersion: availableUpdate?.version,
            lastCheck: lastCheck
        )
        self.pendingChoiceReply = choiceReply ?? (hasLiveChoiceReply ? { _ in } : nil)
        self.pendingReplyRequiresFinalization = self.pendingChoiceReply != nil && {
            if case .readyToInstall = activity {
                return true
            }
            return false
        }()
        self.pendingCancellation = nil
        self.expectedContentLength = nil
    }
    #endif

    func ingestFoundUpdate(version: String, releaseNotes: String?) {
        recordFoundUpdate(version: version, releaseNotes: releaseNotes)
    }

    func ingestStagedUpdate(version: String) {
        recordStagedUpdate(version: version)
    }

    func ingestCycleFinished(error: (any Error)?) {
        guard let error else { return }

        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain else {
            recordFailedCheck()
            return
        }

        switch nsError.code {
        case Int(SUError.noUpdateError.rawValue):
            recordUpToDateCheck()
        case Int(SUError.installationCanceledError.rawValue),
             Int(SUError.installationAuthorizeLaterError.rawValue):
            return
        default:
            recordFailedCheck()
        }
    }

    private func stashChoiceReply(
        _ reply: @escaping (SPUUserUpdateChoice) -> Void,
        requiresFinalization: Bool
    ) {
        pendingChoiceReply = reply
        pendingReplyRequiresFinalization = requiresFinalization
    }

    private func stashCancellation(_ cancellation: @escaping () -> Void) {
        pendingCancellation = cancellation
    }

    private func clearPendingInteractions() {
        pendingChoiceReply = nil
        pendingReplyRequiresFinalization = false
        pendingCancellation = nil
    }

    private func clearPendingCancellation() {
        pendingCancellation = nil
    }

    private func observeExclusivity() {
        guard let exclusivityProvider else {
            applyExclusiveOperationValue(false)
            return
        }

        let current = withObservationTracking {
            exclusivityProvider()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeExclusivity()
            }
        }

        applyExclusiveOperationValue(current)
    }

    private func applyExclusiveOperationValue(_ newValue: Bool) {
        let oldValue = exclusiveOperationInProgress
        exclusiveOperationInProgress = newValue
        onExclusivityReevaluated?(newValue)

        guard oldValue != newValue else { return }
        if !newValue {
            handleExclusiveOperationCleared()
        }
    }

    private func handleExclusiveOperationCleared() {
        if deferredInstallIntent != nil {
            deferredInstallIntent = nil
            if let reply = pendingChoiceReply {
                let requiresFinalization = pendingReplyRequiresFinalization
                pendingChoiceReply = nil
                pendingReplyRequiresFinalization = false
                fireInstallReply(reply, requiresFinalization: requiresFinalization)
            } else {
                checkForUpdates()
            }
            blockedAutomaticCheckDuringExclusive = false
            return
        }

        let blockedCheck = blockedAutomaticCheckDuringExclusive
        let shouldCheck = (availableUpdate != nil || blockedCheck) && !hasLiveSparkleSessionOrReply
        blockedAutomaticCheckDuringExclusive = false

        if shouldCheck {
            checkForUpdates()
        }
    }

    private var hasLiveSparkleSessionOrReply: Bool {
        sparkleSessionInProgress
            || activity != .idle
            || pendingChoiceReply != nil
            || pendingCancellation != nil
            || installFinalizationInFlight
            || installFinalizationCommitted
    }

    private var sparkleSessionInProgress: Bool {
        if let sessionLivenessProvider { return sessionLivenessProvider() }
        return updater?.sessionInProgress ?? false
    }

    private static func defaultPostInstallRecoveryScheduler(_ check: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            check()
        }
    }

    private func fireInstallReply(
        _ reply: @escaping (SPUUserUpdateChoice) -> Void,
        requiresFinalization: Bool
    ) {
        guard requiresFinalization else {
            reply(.install)
            return
        }

        installFinalizationInFlight = true

        // Once finalization starts, the user's explicit install intent is committed;
        // exclusivity is not re-checked before handing control back to Sparkle.
        Task { @MainActor in
            await preInstallFinalizer?()
            installFinalizationCommitted = true
            reply(.install)
            installFinalizationInFlight = false
        }
    }

    private func resumeStagedInstall() {
        guard canCheckForUpdates else {
            Logger.setup.warning("installStagedUpdate() ignored because Sparkle config gate failed")
            return
        }

        guard ensureUpdaterStarted(), let updater else {
            Logger.setup.error("installStagedUpdate() ignored because Sparkle updater failed to start")
            activity = .idle
            recordFailedCheck()
            return
        }

        pendingDownloadIntent = true
        updater.checkForUpdates()
    }

    @discardableResult
    private func recoverCommittedInstallFinalization() -> Bool {
        guard installFinalizationCommitted else { return false }

        installFinalizationCommitted = false
        immediateStagedInstallHandler = nil
        Task { @MainActor in await installFailureRecovery?() }
        return true
    }

    private func currentUpdateVersionForIntent() -> String {
        switch activity {
        case .readyToInstall(let version, _),
             .downloading(let version, _, _),
             .extracting(let version, _),
             .installing(let version):
            return version
        case .idle, .checking:
            return availableUpdate?.version ?? ""
        }
    }

    private func recordFoundUpdate(version: String, releaseNotes: String?, now: Date = Date()) {
        guard !reconciledStatus.matches(availableVersion: version, outcome: .found) else { return }

        availableUpdate = AvailableUpdate(version: version, releaseNotes: releaseNotes)
        reconciledStatus.availableVersion = version
        reconciledStatus.lastCheck = ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
        persistStatus()
    }

    private func recordStagedUpdate(version: String, now: Date = Date()) {
        guard !reconciledStatus.matches(availableVersion: version, outcome: .staged) else { return }

        let releaseNotes = availableUpdate?.version == version ? availableUpdate?.releaseNotes : nil
        availableUpdate = AvailableUpdate(version: version, releaseNotes: releaseNotes)
        reconciledStatus.availableVersion = version
        reconciledStatus.lastCheck = ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .staged)
        persistStatus()
    }

    private func recordUpToDateCheck(now: Date = Date()) {
        guard !reconciledStatus.matches(availableVersion: nil, outcome: .upToDate) else { return }

        availableUpdate = nil
        reconciledStatus.availableVersion = nil
        reconciledStatus.lastCheck = ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .upToDate)
        persistStatus()
    }

    private func recordFailedCheck(now: Date = Date()) {
        pendingDownloadIntent = false
        let preservedVersion = reconciledStatus.availableVersion
        guard !reconciledStatus.matches(availableVersion: preservedVersion, outcome: .failed) else { return }

        reconciledStatus.lastCheck = ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .failed)
        if availableUpdate == nil, let version = reconciledStatus.availableVersion {
            availableUpdate = AvailableUpdate(version: version, releaseNotes: nil)
        }
        persistStatus()
    }

    private func persistStatus() {
        do {
            let data = try JSONEncoder().encode(reconciledStatus)
            defaults.set(data, forKey: Self.statusKey)
        } catch {
            Logger.setup.error("Failed to persist update status: \(String(describing: error), privacy: .public)")
        }
    }

    private func ensureUpdaterStarted() -> Bool {
        if updaterStarted {
            return true
        }

        guard let updater = updater ?? updaterFactory(userDriver, updaterDelegate) else {
            Logger.setup.error("Sparkle updater factory returned nil")
            return false
        }

        self.updater = updater

        do {
            try updater.start()
            updaterStarted = true

            if defaults.string(forKey: Self.feedURLOverrideKey) == nil {
                Logger.setup.info("Sparkle feed URL: using bundled Info.plist feed (no override set)")
            } else if let override = Self.feedURLOverride(from: defaults) {
                Logger.setup.info("Sparkle feed URL override applied from \(Self.feedURLOverrideKey, privacy: .public): \(override, privacy: .public)")
            } else {
                Logger.setup.info("Sparkle feed URL override in \(Self.feedURLOverrideKey, privacy: .public) was rejected (not a valid https URL); falling back to bundled Info.plist feed")
            }

            return true
        } catch {
            Logger.setup.error("Sparkle updater start failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func loadPersistedStatus(from defaults: UserDefaults) -> (status: ReconciledUpdateStatus, migrated: Bool) {
        if let data = defaults.data(forKey: statusKey),
           let decoded = try? JSONDecoder().decode(ReconciledUpdateStatus.self, from: data) {
            return (decoded, false)
        }

        guard let legacyRaw = defaults.string(forKey: legacyLastCheckResultKey) else {
            return (ReconciledUpdateStatus(), false)
        }

        let checkedAt = defaults.object(forKey: legacyLastCheckedAtKey) as? Date ?? Date()
        let parts = legacyRaw.split(separator: ":", maxSplits: 1)

        switch parts.first.map(String.init) {
        case "upToDate":
            return (
                ReconciledUpdateStatus(
                    availableVersion: nil,
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: checkedAt, outcome: .upToDate)
                ),
                true
            )
        case "failed":
            return (
                ReconciledUpdateStatus(
                    availableVersion: nil,
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: checkedAt, outcome: .failed)
                ),
                true
            )
        case "updateFound":
            guard parts.count == 2 else { return (ReconciledUpdateStatus(), true) }
            let version = String(parts[1])
            return (
                ReconciledUpdateStatus(
                    availableVersion: version,
                    lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: checkedAt, outcome: .found)
                ),
                true
            )
        default:
            return (ReconciledUpdateStatus(), true)
        }
    }

    private static func reconcilePersistedStatus(
        _ status: ReconciledUpdateStatus,
        runningVersion: String
    ) -> (status: ReconciledUpdateStatus, changed: Bool) {
        guard status.availableVersion == runningVersion else {
            return (status, false)
        }

        var updated = status
        updated.availableVersion = nil
        updated.lastCheck = ReconciledUpdateStatus.LastCheck(
            checkedAt: status.lastCheck?.checkedAt ?? Date(),
            outcome: .upToDate
        )
        return (updated, true)
    }

    private static func removeLegacyStatusKeys(from defaults: UserDefaults) {
        defaults.removeObject(forKey: legacyLastCheckedAtKey)
        defaults.removeObject(forKey: legacyLastCheckResultKey)
    }
}

private extension ReconciledUpdateStatus {
    func matches(availableVersion: String?, outcome: ReconciledUpdateStatus.Outcome) -> Bool {
        self.availableVersion == availableVersion && lastCheck?.outcome == outcome
    }
}

@MainActor
private final class SparkleUpdaterDelegateAdapter: NSObject, SPUUpdaterDelegate {
    private weak var controller: UpdateController?

    func attach(to controller: UpdateController) {
        self.controller = controller
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard controller?.shouldAllowSparkleUpdateCheck(updateCheck) == false else { return }
        throw NSError(
            domain: "app.solstone.observer.updates",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "update check deferred during journal setup"]
        )
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        controller?.sparkleFeedURLOverride()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        controller?.ingestFoundUpdate(version: item.displayVersionString, releaseNotes: item.itemDescription)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        controller?.ingestCycleFinished(error: error)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Logger.setup.debug("Sparkle downloaded update \(item.displayVersionString, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        Logger.setup.debug("Sparkle extracted update \(item.displayVersionString, privacy: .public)")
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        controller?.ingestStagedUpdate(version: item.displayVersionString)
        controller?.recordImmediateStagedInstallHandler(immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        controller?.ingestCycleFinished(error: error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        controller?.ingestCycleFinished(error: error)
    }
}
