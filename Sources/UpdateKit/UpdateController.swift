import Foundation
import Observation
import SolstoneCore
import Sparkle
import os

@MainActor
public protocol SparkleUpdating: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    func checkForUpdates()
    func checkForUpdatesInBackground()
    var sessionInProgress: Bool { get }
    var userAgentString: String { get }
    func start() throws
}

extension SPUUpdater: SparkleUpdating {}

public enum UpdaterArmState: Equatable, Sendable {
    case notAttempted
    case armed
    case failedToArm(reason: String)
}

@MainActor
@Observable
public final class UpdateController {
    public typealias UpdaterFactory = @MainActor (SparkleUserDriver, any SPUUpdaterDelegate) -> (any SparkleUpdating)?
    public typealias ExclusivityProvider = @MainActor () -> Bool
    public typealias SessionLivenessProvider = @MainActor () -> Bool
    public typealias PreInstallFinalizer = @MainActor () async -> Void
    public typealias InstallFailureRecovery = @MainActor () async -> Void
    public typealias RunningVersionProvider = @MainActor () -> String
    /// Shows the owner the restart prompt for a waiting update and reports their answer:
    /// `true` to restart and install now, `false` to leave it for later.
    public typealias RestartPromptPresenter = @MainActor (_ version: String, _ respond: @escaping @MainActor (Bool) -> Void) -> Void
    public typealias DelayScheduler = @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    private static let statusKey = "solstone.updates.status"
    private static let lastAnnouncedUpdateVersionKey = "solstone.updates.lastAnnouncedUpdateVersion"
    private static let feedURLOverrideKey = "solstone.updates.feedURLOverride"
    private static let legacyLastCheckedAtKey = "solstone.updates.lastCheckedAt"
    private static let legacyLastCheckResultKey = "solstone.updates.lastCheckResult"
    /// How long an update may wait for a restart before the owner is asked to restart now.
    /// A newer release replacing the waiting one does not restart this clock.
    public static let restartPromptThreshold: TimeInterval = 3 * 86_400
    // Sparkle records a skipped version under these keys. UpdateKit offers no skip, and it
    // skips only to cancel a waiting update it is replacing, so it removes the record again.
    private static let sparkleSkipKeys = ["SUSkippedMinorVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion"]
    private static let replacementRetryDelay: TimeInterval = 5
    private static let replacementAttempts = 6
    private static let installRetryDelay: TimeInterval = 1
    private static let installRetryAttempts = 30

    public private(set) var activity: UpdateActivity = .idle
    public private(set) var backgroundDownload: BackgroundDownloadPhase? = nil
    public private(set) var reconciledStatus: ReconciledUpdateStatus
    public private(set) var availableUpdate: AvailableUpdate?
    public private(set) var deferredInstallIntent: DeferredInstallIntent?
    public private(set) var exclusiveOperationInProgress = false
    public private(set) var stagedBlockSuppressed = false

    public private(set) var canCheckForUpdates: Bool
    public private(set) var updaterArmState: UpdaterArmState = .notAttempted
    public private(set) var isRearmingUpdater = false

    private let updaterFactory: UpdaterFactory
    private let userDriver: SparkleUserDriver
    private let updaterDelegate: SparkleUpdaterDelegateAdapter
    private let log: Logger
    private let exclusivityProvider: ExclusivityProvider?
    private let sessionLivenessProvider: SessionLivenessProvider?
    private let preInstallFinalizer: PreInstallFinalizer?
    private let installFailureRecovery: InstallFailureRecovery?
    private let restartPrompt: RestartPromptPresenter?
    private let feedLoader: UpdateFeedProbe.Loader?
    private let now: @MainActor () -> Date
    private let scheduleAfter: DelayScheduler
    private let feedURL: String?
    private let defaults: UserDefaults
    private let announceUpdateVersion: (@MainActor (String) -> Void)?

    private var updater: (any SparkleUpdating)?
    @ObservationIgnored private var sessionObservation: NSKeyValueObservation?
    private var updaterStarted = false
    private var pendingChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var pendingReplyRequiresFinalization = false
    private var pendingCancellation: (() -> Void)?
    private var expectedContentLength: UInt64?
    private var blockedAutomaticCheckDuringExclusive = false
    // Sparkle handoff flags; distinct from AppQuitCoordinator's app committed-exit state.
    private var installFinalizationInFlight = false
    private var installFinalizationCommitted = false
    private var pendingDownloadIntent = false
    // A scheduled Sparkle session resuming a waiting update, held only while the feed is read.
    private var waitingRecheck: UUID?
    // The build of the waiting update being cancelled so a newer release can replace it.
    private var replacingBuild: String?
    private var replacementCheckStarted = false
    private var restartPromptTimer: UUID?
    private var restartPromptShowing = false
    private var chosenInstallVersion: String?
    private var suppressNextInstallChoiceRecord = false

    internal var onExclusivityReevaluated: ((Bool) -> Void)?
    #if DEBUG || SOLSTONE_TEST_SUPPORT
    internal var checkForUpdatesInterceptor: (() -> Void)?
    #endif

    // The updater settings read through to Sparkle, which Observation cannot see,
    // so each one registers its own access and mutation. Without that, a write
    // persists but the settings controls keep drawing the old value.
    public var automaticChecksEnabled: Bool {
        get {
            access(keyPath: \.automaticChecksEnabled)
            return updater?.automaticallyChecksForUpdates ?? true
        }
        set {
            withMutation(keyPath: \.automaticChecksEnabled) {
                updater?.automaticallyChecksForUpdates = newValue
            }
        }
    }

    public func retryStartingUpdater() {
        guard canCheckForUpdates, !isRearmingUpdater else {
            return
        }

        isRearmingUpdater = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            _ = self.ensureUpdaterStarted()
            self.isRearmingUpdater = false
        }
    }

    public var updateCheckInterval: TimeInterval {
        get {
            access(keyPath: \.updateCheckInterval)
            return updater?.updateCheckInterval ?? 86_400
        }
        set {
            withMutation(keyPath: \.updateCheckInterval) {
                updater?.updateCheckInterval = newValue
            }
        }
    }

    public var automaticDownloadsEnabled: Bool {
        get {
            access(keyPath: \.automaticDownloadsEnabled)
            return updater?.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticDownloadsEnabled) {
                updater?.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    public var lastCheckedAt: Date? {
        reconciledStatus.lastCheck?.checkedAt
    }

    private var lastAnnouncedUpdateVersion: String? {
        get {
            defaults.string(forKey: Self.lastAnnouncedUpdateVersionKey)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.lastAnnouncedUpdateVersionKey)
            } else {
                defaults.removeObject(forKey: Self.lastAnnouncedUpdateVersionKey)
            }
        }
    }

    public var hasLiveUpdateReply: Bool {
        pendingChoiceReply != nil
    }

    public var canActOnAvailableUpdateDirectly: Bool {
        activity == .idle && pendingChoiceReply != nil && availableUpdate != nil
    }

    public static var hasValidSparkleConfig: Bool {
        let info = Bundle.main.infoDictionary
        return validateSparkleConfig(
            feedURL: info?["SUFeedURL"] as? String,
            publicKey: info?["SUPublicEDKey"] as? String
        )
    }

    public static func validateSparkleConfig(feedURL: String?, publicKey: String?) -> Bool {
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

    public static func feedURLOverride(from defaults: UserDefaults) -> String? {
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

    public init(
        feedURL: String? = nil,
        publicKey: String? = nil,
        runningVersion: @escaping RunningVersionProvider = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        },
        log: Logger,
        errorDomain: String,
        exclusivity: ExclusivityProvider? = nil,
        sessionInProgress: SessionLivenessProvider? = nil,
        preInstallFinalizer: PreInstallFinalizer? = nil,
        installFailureRecovery: InstallFailureRecovery? = nil,
        restartPrompt: RestartPromptPresenter? = nil,
        announce: (@MainActor (String) -> Void)? = nil,
        defaults: UserDefaults = .standard,
        feedLoader: UpdateFeedProbe.Loader? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        scheduleAfter: DelayScheduler? = nil,
        updaterFactory: @escaping UpdaterFactory
    ) {
        let info = Bundle.main.infoDictionary
        let resolvedFeedURL = feedURL ?? info?["SUFeedURL"] as? String
        self.updaterFactory = updaterFactory
        self.userDriver = SparkleUserDriver(log: log)
        self.updaterDelegate = SparkleUpdaterDelegateAdapter(log: log, errorDomain: errorDomain)
        self.log = log
        self.exclusivityProvider = exclusivity
        self.sessionLivenessProvider = sessionInProgress
        self.preInstallFinalizer = preInstallFinalizer
        self.installFailureRecovery = installFailureRecovery
        self.restartPrompt = restartPrompt
        self.feedLoader = feedLoader
        self.now = now
        self.scheduleAfter = scheduleAfter ?? Self.defaultScheduleAfter
        self.feedURL = resolvedFeedURL
        self.defaults = defaults
        self.announceUpdateVersion = announce
        self.canCheckForUpdates = Self.validateSparkleConfig(
            feedURL: resolvedFeedURL,
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
            log.warning("Sparkle disabled: missing or invalid SUFeedURL / SUPublicEDKey")
        }

        observeExclusivity()
        armRestartPrompt()
    }

    public convenience init(
        log: Logger,
        errorDomain: String,
        exclusivity: ExclusivityProvider? = nil,
        preInstallFinalizer: PreInstallFinalizer? = nil,
        installFailureRecovery: InstallFailureRecovery? = nil,
        restartPrompt: RestartPromptPresenter? = nil,
        announce: (@MainActor (String) -> Void)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            log: log,
            errorDomain: errorDomain,
            exclusivity: exclusivity,
            preInstallFinalizer: preInstallFinalizer,
            installFailureRecovery: installFailureRecovery,
            restartPrompt: restartPrompt,
            announce: announce,
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

    public func checkForUpdates() {
        guard canCheckForUpdates else {
            log.warning("checkForUpdates() ignored because Sparkle config gate failed")
            return
        }

        guard !hasLiveSparkleSessionOrReply else {
            log.info("checkForUpdates() ignored because a Sparkle update session is already active")
            return
        }

        #if DEBUG || SOLSTONE_TEST_SUPPORT
        if let checkForUpdatesInterceptor {
            checkForUpdatesInterceptor()
            beginUserInitiatedCheck(cancellation: {})
            return
        }
        #endif

        guard ensureUpdaterStarted(), let updater else {
            log.error("checkForUpdates() ignored because Sparkle updater failed to start")
            activity = .idle
            recordFailedCheck()
            return
        }

        updater.checkForUpdates()
    }

    func cancel() {
        clearInstallChoice()
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
            log.info("download() ignored because a Sparkle update session is already active")
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
        waitingRecheck = nil
        fireInstallReply(reply, requiresFinalization: requiresFinalization)
    }

    /// The owner's install-now for whatever update is waiting: a staged one installs and
    /// restarts at once; a downloaded one that needs an administrator asks for one first.
    public func installWaitingUpdate() {
        installWaitingUpdate(attempt: 1)
    }

    private func installWaitingUpdate(attempt: Int) {
        if pendingChoiceReply != nil {
            install()
        } else if updateIsStaged {
            installStagedUpdate()
        } else if availableUpdate != nil {
            // Sparkle ignores a check while a session is open; wait it out rather than drop the press.
            if sparkleSessionInProgress, attempt < Self.installRetryAttempts {
                scheduleAfter(Self.installRetryDelay) { [weak self] in
                    self?.installWaitingUpdate(attempt: attempt + 1)
                }
                return
            }
            download()
        }
    }

    func dismiss() {
        clearInstallChoice()
        guard !installFinalizationInFlight else { return }

        pendingDownloadIntent = false
        pendingChoiceReply?(.dismiss)
        clearPendingInteractions()
        deferredInstallIntent = nil
        activity = .idle
        recoverCommittedInstallFinalization()
    }

    func suppressStagedBlock() {
        guard updateIsStaged, !installFinalizationInFlight, !installFinalizationCommitted else { return }
        stagedBlockSuppressed = true
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
        buildVersion: String = "",
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
            return
        }

        // A scheduled Sparkle session that shows an update stays open until it gets an
        // answer, and while it is open Sparkle schedules no further checks. Only the owner's
        // own check keeps one open; a scheduled one is answered here.
        guard !state.userInitiated else { return }
        switch state.stage {
        case .notDownloaded:
            // The next scheduled check reads the feed again and finds the newest.
            answerPendingReply(.dismiss)
        case .downloaded, .installing:
            recheckWaitingUpdate(buildVersion: buildVersion, stage: state.stage)
        @unknown default:
            answerPendingReply(.dismiss)
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
        clearInstallChoice()
        pendingDownloadIntent = false
        clearPendingInteractions()
        activity = .idle
        deferredInstallIntent = nil
    }

    func presentUpdaterError(_ error: Error) {
        clearInstallChoice()
        recoverCommittedInstallFinalization()
        log.error("Sparkle error: \(String(describing: error), privacy: .public)")
        clearPendingInteractions()
        pendingDownloadIntent = false
        activity = .idle
    }

    func installStagedUpdate() {
        guard updateIsStaged else { return }
        guard !installFinalizationInFlight, !installFinalizationCommitted else { return }

        // A scheduled session may be holding the waiting update while the feed is read.
        if pendingChoiceReply != nil {
            install()
            return
        }
        resumeStagedInstall()
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
        let version = availableUpdate?.version ?? ""
        activity = .readyToInstall(
            version: version,
            releaseNotes: availableUpdate?.releaseNotes
        )

        guard let chosenInstallVersion,
              !chosenInstallVersion.isEmpty,
              let availableVersion = availableUpdate?.version,
              !availableVersion.isEmpty,
              chosenInstallVersion == availableVersion
        else {
            clearInstallChoice()
            return
        }

        suppressNextInstallChoiceRecord = true
        install()
        if pendingChoiceReply == nil {
            activity = .installing(version: version)
        }
        self.chosenInstallVersion = nil
        if pendingChoiceReply != nil, deferredInstallIntent == nil {
            suppressNextInstallChoiceRecord = false
        }
    }

    func installingUpdate() {
        clearPendingCancellation()
        activity = .installing(version: availableUpdate?.version ?? "")
    }

    func updateInstalledAndRelaunched() {
        clearInstallChoice()
        installFinalizationCommitted = false
        clearPendingInteractions()
        deferredInstallIntent = nil
        activity = .idle
    }

    func dismissUpdateInstallation() {
        clearInstallChoice()
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

    var canStartManualCheck: Bool {
        canCheckForUpdates && updaterArmFailureReason == nil && !hasLiveSparkleSessionOrReply
    }

    var canRetry: Bool {
        canStartManualCheck
    }

    var canCheckAgainFromDeferred: Bool {
        canStartManualCheck
    }

    var canDownload: Bool {
        canActOnAvailableUpdateDirectly || canStartManualCheck
    }

    var updatesPaneLiveness: UpdatesPaneLiveness {
        currentUpdatesPaneLiveness
    }

    private var currentUpdatesPaneLiveness: UpdatesPaneLiveness {
        UpdatesPaneLiveness(
            canCheckForUpdates: canCheckForUpdates,
            updaterArmFailureReason: updaterArmFailureReason,
            isRearmingUpdater: isRearmingUpdater,
            sparkleSessionInProgress: sparkleSessionInProgress,
            activity: activity,
            hasPendingChoiceReply: pendingChoiceReply != nil,
            hasPendingCancellation: pendingCancellation != nil,
            installFinalizationInFlight: installFinalizationInFlight,
            installFinalizationCommitted: installFinalizationCommitted
        )
    }

    private var updaterArmFailureReason: String? {
        if case .failedToArm(let reason) = updaterArmState {
            return reason
        }
        return nil
    }

    public var durableUpdateStatus: DurableUpdateStatus {
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
        if case .failedToArm = updaterArmState {
            return "not_running"
        }

        switch activity {
        case .idle:
            if backgroundDownload != nil {
                return "downloading_background"
            }

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

    #if DEBUG || SOLSTONE_TEST_SUPPORT
    func applyDebugFixture(
        activity: UpdateActivity,
        availableUpdate: AvailableUpdate? = nil,
        lastCheck: ReconciledUpdateStatus.LastCheck? = nil,
        deferredInstallIntent: DeferredInstallIntent? = nil,
        backgroundDownload: BackgroundDownloadPhase? = nil,
        stagedBlockSuppressed: Bool = false,
        hasLiveChoiceReply: Bool = false,
        choiceReply: ((SPUUserUpdateChoice) -> Void)? = nil
    ) {
        self.activity = activity
        self.backgroundDownload = backgroundDownload
        self.availableUpdate = availableUpdate
        self.deferredInstallIntent = deferredInstallIntent
        self.stagedBlockSuppressed = stagedBlockSuppressed
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

    public func evaluatePendingUpdateAnnouncement() {
        evaluateAnnouncement()
    }

    func ingestBackgroundDownloadStarted(version: String?) {
        backgroundDownload = .downloading(version: version)
    }

    func ingestBackgroundDownloadFinished(version: String?) {
        backgroundDownload = .finishingUp(version: version)
    }

    func ingestStagedUpdate(version: String, build: String = "") {
        backgroundDownload = nil
        stagedBlockSuppressed = false
        if replacingBuild != build {
            replacingBuild = nil
        }
        recordStagedUpdate(version: version)
        markWaiting()
        evaluateRestartPrompt()
    }

    func ingestCycleFinished(error: (any Error)?) {
        backgroundDownload = nil

        if replacementCheckStarted {
            // The check that replaces a cancelled update has ended. If it staged nothing,
            // the next scheduled check continues from the feed.
            replacementCheckStarted = false
            replacingBuild = nil
        }

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
        waitingRecheck = nil
    }

    private func stashCancellation(_ cancellation: @escaping () -> Void) {
        pendingCancellation = cancellation
    }

    private func clearPendingInteractions() {
        pendingChoiceReply = nil
        pendingReplyRequiresFinalization = false
        pendingCancellation = nil
        waitingRecheck = nil
    }

    private func clearInstallChoice() {
        chosenInstallVersion = nil
        suppressNextInstallChoiceRecord = false
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
                waitingRecheck = nil
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
        currentUpdatesPaneLiveness.hasLiveSparkleSessionOrReply
    }

    private var sparkleSessionInProgress: Bool {
        access(keyPath: \.sparkleSessionInProgress)
        if let sessionLivenessProvider { return sessionLivenessProvider() }
        return updater?.sessionInProgress ?? false
    }

    private static func defaultScheduleAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            // The continuous clock keeps counting while the Mac sleeps, so a wake past the
            // deadline runs the work promptly.
            try? await Task.sleep(for: .seconds(max(delay, 0)), clock: .continuous)
            work()
        }
    }

    private func fireInstallReply(
        _ reply: @escaping (SPUUserUpdateChoice) -> Void,
        requiresFinalization: Bool
    ) {
        if suppressNextInstallChoiceRecord {
            suppressNextInstallChoiceRecord = false
        } else {
            let version = currentUpdateVersionForIntent()
            chosenInstallVersion = version.isEmpty ? nil : version
        }

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

    private func resumeStagedInstall(attempt: Int = 1) {
        guard canCheckForUpdates else {
            log.warning("installStagedUpdate() ignored because Sparkle config gate failed")
            return
        }

        guard ensureUpdaterStarted(), let updater else {
            log.error("installStagedUpdate() ignored because Sparkle updater failed to start")
            activity = .idle
            recordFailedCheck()
            return
        }

        // Sparkle ignores a check while a session is open, as it briefly is between scheduled
        // checks. The owner pressed install, so wait it out rather than drop the press.
        if sparkleSessionInProgress {
            guard attempt < Self.installRetryAttempts else {
                log.error("installStagedUpdate() gave up: Sparkle stayed busy")
                return
            }
            scheduleAfter(Self.installRetryDelay) { [weak self] in
                guard let self, self.updateIsStaged, self.pendingChoiceReply == nil else { return }
                self.resumeStagedInstall(attempt: attempt + 1)
            }
            return
        }

        pendingDownloadIntent = true
        updater.checkForUpdates()
    }

    @discardableResult
    private func recoverCommittedInstallFinalization() -> Bool {
        guard installFinalizationCommitted else { return false }

        installFinalizationCommitted = false
        stagedBlockSuppressed = false
        Task { @MainActor in await installFailureRecovery?() }
        return true
    }

    // MARK: - A waiting update

    private func answerPendingReply(_ choice: SPUUserUpdateChoice) {
        guard let reply = pendingChoiceReply else { return }
        clearPendingInteractions()
        activity = .idle
        reply(choice)
    }

    /// Sparkle resumed a waiting update on its daily schedule without reading the feed.
    /// Read it once: if a newer release is out, cancel the waiting one so Sparkle takes the
    /// newest; otherwise leave it waiting and let the session end so checks continue.
    private func recheckWaitingUpdate(buildVersion: String, stage: SPUUserUpdateStage) {
        if stage == .downloaded {
            // Downloaded but needing an administrator to install: it waits for the owner.
            markWaiting()
        }

        if let replacingBuild, replacingBuild == buildVersion {
            // Still the update being replaced; its installer had not exited yet.
            replacementCheckStarted = false
            answerPendingReply(.skip)
            continueReplacement(attempt: 1)
            return
        }

        let token = UUID()
        waitingRecheck = token
        Task { @MainActor [weak self] in
            guard let self else { return }
            let newest = await self.newestFeedBuild()
            // The owner pressed install, or another session replaced this one.
            guard self.waitingRecheck == token else { return }

            if let newest, !buildVersion.isEmpty,
               UpdateFeedProbe.isNewer(newest, than: buildVersion),
               self.reconciledStatus.replacedForBuild.map({ UpdateFeedProbe.isNewer(newest, than: $0) }) ?? true {
                self.log.notice("Replacing waiting update \(buildVersion, privacy: .public) with feed build \(newest, privacy: .public)")
                self.reconciledStatus.replacedForBuild = newest
                self.persistStatus()
                self.replacingBuild = buildVersion
                self.answerPendingReply(.skip)
                self.continueReplacement(attempt: 1)
            } else {
                if newest != nil {
                    self.log.notice("Waiting update \(buildVersion, privacy: .public) is still the newest")
                    self.recordWaitingRecheck()
                }
                self.answerPendingReply(.dismiss)
            }
            self.evaluateRestartPrompt()
        }
    }

    private func newestFeedBuild() async -> String? {
        guard let feedURL, let url = URL(string: feedURL), let updater else { return nil }
        let override = Self.feedURLOverride(from: defaults)
        let origin = UpdateFeedProbe.approvedOrigin(feedOverride: override)
        let target = override.flatMap(URL.init(string:)) ?? url
        guard UpdateFeedProbe.isApproved(target, origin: origin) else {
            log.error("Waiting-update feed read refused: feed address is outside the update origin")
            return nil
        }
        let loader = feedLoader ?? UpdateFeedProbe.confinedLoader(origin: origin)
        let request = UpdateFeedProbe.request(feedURL: target, userAgent: updater.userAgentString)
        do {
            let (data, response) = try await loader(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log.error("Waiting-update feed read failed: unexpected response")
                return nil
            }
            return UpdateFeedProbe.newestEligibleBuild(inAppcast: data, systemVersion: UpdateFeedProbe.systemVersion)
        } catch {
            log.error("Waiting-update feed read failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// After cancelling the waiting update, start Sparkle's own background check once the
    /// cancelled session has ended, so it downloads and verifies the newest release.
    private func continueReplacement(attempt: Int) {
        scheduleAfter(Self.replacementRetryDelay) { [weak self] in
            guard let self, self.replacingBuild != nil else { return }
            for key in Self.sparkleSkipKeys {
                self.defaults.removeObject(forKey: key)
            }
            guard !self.sparkleSessionInProgress else {
                if attempt < Self.replacementAttempts {
                    self.continueReplacement(attempt: attempt + 1)
                } else {
                    self.log.error("Waiting-update replacement gave up; the next scheduled check continues it")
                    self.replacingBuild = nil
                }
                return
            }
            self.replacementCheckStarted = true
            self.updater?.checkForUpdatesInBackground()
        }
    }

    private func recordWaitingRecheck() {
        guard let lastCheck = reconciledStatus.lastCheck else { return }
        reconciledStatus.lastCheck = ReconciledUpdateStatus.LastCheck(checkedAt: now(), outcome: lastCheck.outcome)
        persistStatus()
    }

    private func markWaiting() {
        guard reconciledStatus.waitingSince == nil else { return }
        reconciledStatus.waitingSince = now()
        persistStatus()
        armRestartPrompt()
    }

    // MARK: - Restart prompt

    private var restartPromptDueAt: Date? {
        guard restartPrompt != nil, let waitingSince = reconciledStatus.waitingSince, availableUpdate != nil else {
            return nil
        }
        let due = waitingSince.addingTimeInterval(Self.restartPromptThreshold)
        guard let promptedAt = reconciledStatus.restartPromptedAt else { return due }
        return max(due, promptedAt.addingTimeInterval(Self.restartPromptThreshold))
    }

    /// Wakes once when the waiting update reaches the threshold, whatever Sparkle's own
    /// check cadence is, so the prompt doesn't depend on the owner's update settings.
    private func armRestartPrompt() {
        guard let due = restartPromptDueAt else {
            restartPromptTimer = nil
            return
        }
        let token = UUID()
        restartPromptTimer = token
        scheduleAfter(max(due.timeIntervalSince(now()), 60)) { [weak self] in
            guard let self, self.restartPromptTimer == token else { return }
            self.evaluateRestartPrompt()
        }
    }

    func evaluateRestartPrompt() {
        guard let restartPrompt, let due = restartPromptDueAt, !restartPromptShowing else { return }
        guard now() >= due else {
            armRestartPrompt()
            return
        }
        // Never over an install, a download or an owner choice already on screen.
        guard activity == .idle, !installFinalizationInFlight, !installFinalizationCommitted,
              !exclusiveOperationInProgress, replacingBuild == nil,
              let version = availableUpdate?.version
        else {
            armRestartPrompt()
            return
        }

        reconciledStatus.restartPromptedAt = now()
        persistStatus()
        restartPromptShowing = true
        log.notice("Asking the owner to restart for waiting update \(version, privacy: .public)")
        restartPrompt(version) { [weak self] restartNow in
            guard let self else { return }
            self.restartPromptShowing = false
            if restartNow {
                self.installWaitingUpdate()
            } else {
                self.armRestartPrompt()
            }
        }
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
        defer { evaluateAnnouncement() }

        if reconciledStatus.matches(availableVersion: version, outcome: .staged) {
            let notes = releaseNotes ?? (availableUpdate?.version == version ? availableUpdate?.releaseNotes : nil)
            availableUpdate = AvailableUpdate(version: version, releaseNotes: notes)
            reconciledStatus.availableVersion = version
            reconciledStatus.lastCheck = ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .staged)
            persistStatus()
            return
        }

        let notes = releaseNotes ?? (availableUpdate?.version == version ? availableUpdate?.releaseNotes : nil)
        availableUpdate = AvailableUpdate(version: version, releaseNotes: notes)
        reconciledStatus.availableVersion = version
        reconciledStatus.lastCheck = ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
        persistStatus()
    }

    private func recordStagedUpdate(version: String, now: Date = Date()) {
        defer { evaluateAnnouncement() }

        guard !reconciledStatus.matches(availableVersion: version, outcome: .staged) else { return }

        let releaseNotes = availableUpdate?.version == version ? availableUpdate?.releaseNotes : nil
        availableUpdate = AvailableUpdate(version: version, releaseNotes: releaseNotes)
        reconciledStatus.availableVersion = version
        reconciledStatus.lastCheck = ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .staged)
        persistStatus()
    }

    private func evaluateAnnouncement() {
        guard let announceUpdateVersion else { return }
        guard let version = updateAnnouncementVersion(
            for: durableUpdateStatus,
            lastAnnounced: lastAnnouncedUpdateVersion
        ) else {
            return
        }

        lastAnnouncedUpdateVersion = version
        log.info("Update notification announcement recorded for version \(version, privacy: .public)")
        announceUpdateVersion(version)
    }

    private func recordUpToDateCheck(now: Date = Date()) {
        availableUpdate = nil
        reconciledStatus.availableVersion = nil
        reconciledStatus.lastCheck = ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .upToDate)
        reconciledStatus.clearWaiting()
        persistStatus()
        armRestartPrompt()
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
            log.error("Failed to persist update status: \(String(describing: error), privacy: .public)")
        }
    }

    private func ensureUpdaterStarted() -> Bool {
        if updaterStarted {
            updaterArmState = .armed
            return true
        }

        guard let updater = updater ?? updaterFactory(userDriver, updaterDelegate) else {
            updaterArmState = .failedToArm(reason: Self.updaterFactoryNilReason)
            log.error("Sparkle updater factory returned nil")
            return false
        }

        self.updater = updater
        if sessionObservation == nil, let sparkle = updater as? SPUUpdater {
            sessionObservation = sparkle.observe(\.sessionInProgress, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    // Sparkle remains the authority; notify readers of the computed value.
                    self?.withMutation(keyPath: \.sparkleSessionInProgress) {}
                }
            }
        }

        do {
            try updater.start()
            updaterStarted = true
            updaterArmState = .armed

            if defaults.string(forKey: Self.feedURLOverrideKey) == nil {
                log.info("Sparkle feed URL: using bundled Info.plist feed (no override set)")
            } else if let override = Self.feedURLOverride(from: defaults) {
                log.info("Sparkle feed URL override applied from \(Self.feedURLOverrideKey, privacy: .public): \(override, privacy: .public)")
            } else {
                log.info("Sparkle feed URL override in \(Self.feedURLOverrideKey, privacy: .public) was rejected (not a valid https URL); falling back to bundled Info.plist feed")
            }

            return true
        } catch {
            updaterArmState = .failedToArm(reason: Self.updaterStartFailedReason)
            log.error("Sparkle updater start failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static let updaterFactoryNilReason = "the update system couldn't be prepared."
    private static let updaterStartFailedReason = "the updater couldn't start."

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
            if status.availableVersion == nil, status.waitingSince != nil || status.restartPromptedAt != nil {
                var updated = status
                updated.clearWaiting()
                return (updated, true)
            }
            return (status, false)
        }

        var updated = status
        updated.availableVersion = nil
        updated.lastCheck = ReconciledUpdateStatus.LastCheck(
            checkedAt: status.lastCheck?.checkedAt ?? Date(),
            outcome: .upToDate
        )
        updated.clearWaiting()
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

    mutating func clearWaiting() {
        waitingSince = nil
        restartPromptedAt = nil
        replacedForBuild = nil
    }
}

@MainActor
private final class SparkleUpdaterDelegateAdapter: NSObject, SPUUpdaterDelegate {
    private weak var controller: UpdateController?
    private let log: Logger
    private let errorDomain: String

    init(log: Logger, errorDomain: String) {
        self.log = log
        self.errorDomain = errorDomain
        super.init()
    }

    func attach(to controller: UpdateController) {
        self.controller = controller
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard controller?.shouldAllowSparkleUpdateCheck(updateCheck) == false else { return }
        throw NSError(
            domain: errorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "update check deferred during journal setup"]
        )
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        let explicitFeed = controller?.sparkleFeedURLOverride()
        // The patched downloader consumes and strips this local policy before contact.
        // Refresh it with the feed for each cycle; appcast contents cannot select it.
        var headers = updater.httpHeaders ?? [:]
        headers["X-Solstone-Update-Origin"] = explicitFeed
        updater.httpHeaders = headers
        return explicitFeed
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        controller?.ingestFoundUpdate(version: item.displayVersionString, releaseNotes: item.itemDescription)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        controller?.ingestBackgroundDownloadStarted(version: backgroundVersion(from: item))
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        controller?.ingestCycleFinished(error: error)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        log.debug("Sparkle downloaded update \(item.displayVersionString, privacy: .public)")
        controller?.ingestBackgroundDownloadFinished(version: backgroundVersion(from: item))
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        log.debug("Sparkle extracted update \(item.displayVersionString, privacy: .public)")
    }

    // Returning false leaves Sparkle's scheduler running while the update waits for quit.
    // Returning true would hold Sparkle's session open until the app quits, and Sparkle
    // would schedule no further checks for as long as the app kept running. Install now
    // goes through Sparkle's own resumed session instead (`installStagedUpdate`).
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        controller?.ingestStagedUpdate(version: item.displayVersionString, build: item.versionString)
        return false
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        controller?.ingestCycleFinished(error: error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        controller?.ingestCycleFinished(error: error)
    }

    private func backgroundVersion(from item: SUAppcastItem) -> String? {
        let version = item.displayVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}
