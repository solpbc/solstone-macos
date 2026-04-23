import Foundation
import Observation
import Sparkle
import os

@MainActor
@Observable
final class UpdateController {
    typealias UpdaterFactory = @MainActor (SparkleUserDriver) -> SPUUpdater?

    var state: UpdateState = .idle {
        didSet { handleStateTransition(from: oldValue, to: state) }
    }

    private(set) var canCheckForUpdates: Bool

    private let updaterFactory: UpdaterFactory
    private let userDriver: SparkleUserDriver

    private var updater: SPUUpdater?
    private var updaterStarted = false
    private var pendingChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var pendingCancellation: (() -> Void)?
    private var noUpdateResetTask: Task<Void, Never>?

    private(set) var latestVersion: String?
    private(set) var latestReleaseNotes: String?
    private var expectedContentLength: UInt64?

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
        self.userDriver.attach(to: self)

        guard canCheckForUpdates else {
            Logger.setup.warning("Sparkle disabled: missing or invalid SUFeedURL / SUPublicEDKey")
            return
        }

        _ = ensureUpdaterStarted()
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

        updater.checkForUpdates()
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
            return true
        } catch {
            Logger.setup.error("Sparkle updater start failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func handleStateTransition(from oldValue: UpdateState, to newValue: UpdateState) {
        noUpdateResetTask?.cancel()

        guard newValue == .noUpdateAvailable else {
            return
        }

        noUpdateResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.state == .noUpdateAvailable else { return }
            self.state = .idle
        }
    }
}
