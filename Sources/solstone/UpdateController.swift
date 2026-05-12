import Foundation
import Observation
import Sparkle
import os

@MainActor
@Observable
final class UpdateController {
    typealias UpdaterFactory = @MainActor (SparkleUserDriver) -> SPUUpdater?

    private static let lastCheckedAtKey = "solstone.updates.lastCheckedAt"
    private static let lastCheckResultKey = "solstone.updates.lastCheckResult"
    private static let stashKey = "solstone.installer.preInstallerAutoCheckPreference"

    var state: UpdateState = .idle

    private(set) var canCheckForUpdates: Bool

    private let updaterFactory: UpdaterFactory
    private let userDriver: SparkleUserDriver

    private var updater: SPUUpdater?
    private var updaterStarted = false
    private var pendingChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var pendingCancellation: (() -> Void)?

    private(set) var latestVersion: String?
    private(set) var latestReleaseNotes: String?
    private(set) var lastCheckedAt: Date?
    private(set) var lastCheckResult: LastCheckResult?
    private var expectedContentLength: UInt64?
    private var _automaticChecksEnabled: Bool = true
    private var preInstallerAutoCheckPreference: Bool?
    private var _updateCheckInterval: TimeInterval = 86_400
    private var _automaticDownloadsEnabled: Bool = false

    var automaticChecksEnabled: Bool {
        get { _automaticChecksEnabled }
        set {
            _automaticChecksEnabled = newValue
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    var updateCheckInterval: TimeInterval {
        get { _updateCheckInterval }
        set {
            _updateCheckInterval = newValue
            updater?.updateCheckInterval = newValue
        }
    }

    var automaticDownloadsEnabled: Bool {
        get { _automaticDownloadsEnabled }
        set {
            _automaticDownloadsEnabled = newValue
            updater?.automaticallyDownloadsUpdates = newValue
        }
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

    init(feedURL: String? = nil, publicKey: String? = nil, updaterFactory: @escaping UpdaterFactory) {
        let info = Bundle.main.infoDictionary
        self.updaterFactory = updaterFactory
        self.userDriver = SparkleUserDriver()
        self.canCheckForUpdates = Self.validateSparkleConfig(
            feedURL: feedURL ?? info?["SUFeedURL"] as? String,
            publicKey: publicKey ?? info?["SUPublicEDKey"] as? String
        )

        let defaults = UserDefaults.standard
        self.lastCheckedAt = defaults.object(forKey: Self.lastCheckedAtKey) as? Date
        self.lastCheckResult = defaults.string(forKey: Self.lastCheckResultKey).flatMap(Self.decode)

        self.userDriver.attach(to: self)

        if canCheckForUpdates {
            _ = ensureUpdaterStarted()
        } else {
            Logger.setup.warning("Sparkle disabled: missing or invalid SUFeedURL / SUPublicEDKey")
        }

        // Restore auto-check preference if a prior install was interrupted before installerDidFinish.
        if let stashedAny = defaults.object(forKey: Self.stashKey),
           let stashed = stashedAny as? Bool {
            automaticChecksEnabled = stashed
            defaults.removeObject(forKey: Self.stashKey)
        }
    }

    convenience init() {
        self.init { userDriver in
            SPUUpdater(
                hostBundle: .main,
                applicationBundle: .main,
                userDriver: userDriver,
                delegate: nil
            )
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else {
            Logger.setup.warning("checkForUpdates() ignored because Sparkle config gate failed")
            return
        }

        guard ensureUpdaterStarted(), let updater else {
            Logger.setup.error("checkForUpdates() ignored because Sparkle updater failed to start")
            state = .error(message: UpdatesCopy.errorMessage())
            return
        }

        if state != .checking {
            state = .checking
        }

        updater.checkForUpdates()
    }

    func installerDidStart() {
        if preInstallerAutoCheckPreference == nil {
            preInstallerAutoCheckPreference = _automaticChecksEnabled
            UserDefaults.standard.set(_automaticChecksEnabled, forKey: Self.stashKey)
        }
        cancel()
        automaticChecksEnabled = false
    }

    func installerDidFinish() {
        if let prior = preInstallerAutoCheckPreference {
            automaticChecksEnabled = prior
            preInstallerAutoCheckPreference = nil
        }
        UserDefaults.standard.removeObject(forKey: Self.stashKey)
    }

    func cancel() {
        pendingCancellation?()
        clearPendingInteractions()
        state = .idle
    }

    func install() {
        pendingChoiceReply?(.install)
        pendingChoiceReply = nil
    }

    func dismiss() {
        pendingChoiceReply?(.dismiss)
        clearPendingInteractions()
        state = .idle
    }

    func stashChoiceReply(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingChoiceReply = reply
    }

    func stashCancellation(_ cancellation: @escaping () -> Void) {
        pendingCancellation = cancellation
    }

    func clearPendingInteractions() {
        pendingChoiceReply = nil
        pendingCancellation = nil
    }

    func clearPendingCancellation() {
        pendingCancellation = nil
    }

    func setLatestUpdate(version: String, releaseNotes: String?) {
        latestVersion = version
        latestReleaseNotes = releaseNotes
    }

    func updateReleaseNotes(_ releaseNotes: String?) {
        latestReleaseNotes = releaseNotes

        switch state {
        case .updateAvailable(let version, _):
            state = .updateAvailable(version: version, releaseNotes: releaseNotes)
        case .readyToInstall(let version, _):
            state = .readyToInstall(version: version, releaseNotes: releaseNotes)
        default:
            break
        }
    }

    func recordExpectedContentLength(_ length: UInt64) {
        expectedContentLength = length

        if case .downloading(let version, let receivedBytes, _) = state {
            state = .downloading(version: version, receivedBytes: receivedBytes, totalBytes: length)
        }
    }

    func appendDownloadedBytes(_ length: UInt64) {
        let version = latestVersion ?? ""

        switch state {
        case .downloading(_, let receivedBytes, let totalBytes):
            state = .downloading(version: version, receivedBytes: receivedBytes + length, totalBytes: totalBytes)
        default:
            state = .downloading(version: version, receivedBytes: length, totalBytes: expectedContentLength)
        }
    }

    func setOpaqueError(_ error: Error) {
        Logger.setup.error("Sparkle error: \(String(describing: error), privacy: .public)")
        clearPendingInteractions()
        state = .error(message: UpdatesCopy.errorMessage())
    }

    func updateLastCheck(_ result: LastCheckResult, now: Date = Date()) {
        lastCheckedAt = now
        lastCheckResult = result

        let defaults = UserDefaults.standard
        defaults.set(now, forKey: Self.lastCheckedAtKey)
        defaults.set(Self.encode(result), forKey: Self.lastCheckResultKey)
    }

    private func ensureUpdaterStarted() -> Bool {
        if updaterStarted {
            return true
        }

        guard let updater = updater ?? updaterFactory(userDriver) else {
            Logger.setup.error("Sparkle updater factory returned nil")
            return false
        }

        self.updater = updater

        do {
            try updater.start()
            updaterStarted = true
            refreshUpdaterSettings(from: updater)
            return true
        } catch {
            Logger.setup.error("Sparkle updater start failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func refreshUpdaterSettings(from updater: SPUUpdater) {
        _automaticChecksEnabled = updater.automaticallyChecksForUpdates
        _updateCheckInterval = updater.updateCheckInterval
        _automaticDownloadsEnabled = updater.automaticallyDownloadsUpdates
    }

    private static func encode(_ result: LastCheckResult) -> String {
        switch result {
        case .upToDate:
            return "upToDate"
        case .updateFound(let version):
            return "updateFound:\(version)"
        case .failed:
            return "failed"
        }
    }

    private static func decode(_ raw: String) -> LastCheckResult? {
        let parts = raw.split(separator: ":", maxSplits: 1)

        switch parts.first.map(String.init) {
        case "upToDate":
            return .upToDate
        case "failed":
            return .failed
        case "updateFound":
            guard parts.count == 2 else { return nil }
            return .updateFound(version: String(parts[1]))
        default:
            return nil
        }
    }
}
