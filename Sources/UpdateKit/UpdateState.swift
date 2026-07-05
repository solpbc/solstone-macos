import Foundation

/// Update state has two layers:
///
/// - `ReconciledUpdateStatus` is the durable fact persisted across launches. It
///   remembers the latest version Sparkle found and the most recent check
///   outcome. A found result sets `availableVersion`, a definitive up-to-date
///   result clears it, a staged result restores a downloaded-and-staged update,
///   and a failed check preserves it.
/// - `UpdateActivity` is only live Sparkle activity. It must not be restored
///   from disk because downloading, extraction, ready-to-install, and installing
///   states are backed by Sparkle replies or sessions that only exist in memory.
///
/// On launch, a persisted available version equal to the running bundle display
/// version is reconciled to up-to-date and cleared. Any other persisted version
/// remains available and is surfaced with a download affordance; if no live
/// Sparkle reply exists, the download starts a user-initiated check to rehydrate
/// the callback and then auto-continues with the install.
public struct AvailableUpdate: Equatable, Sendable {
    public var version: String
    public var releaseNotes: String?

    public init(version: String, releaseNotes: String?) {
        self.version = version
        self.releaseNotes = releaseNotes
    }
}

public enum UpdateActivity: Equatable, Sendable {
    case idle
    case checking
    case downloading(version: String, receivedBytes: UInt64, totalBytes: UInt64?)
    case extracting(version: String, progress: Double)
    case readyToInstall(version: String, releaseNotes: String?)
    case installing(version: String)
}

public enum BackgroundDownloadPhase: Equatable, Sendable {
    case downloading(version: String?)
    case finishingUp(version: String?)
}

public enum DurableUpdateStatus: Equatable, Sendable {
    case deferred(version: String)
    case staged(version: String, releaseNotes: String?)
    case failedWithAvailable(version: String)
    case available(version: String, releaseNotes: String?)
    case failed
    case upToDate
    case idle
}

public struct ReconciledUpdateStatus: Codable, Equatable, Sendable {
    public var availableVersion: String?
    public var lastCheck: LastCheck?

    public init(availableVersion: String? = nil, lastCheck: LastCheck? = nil) {
        self.availableVersion = availableVersion
        self.lastCheck = lastCheck
    }

    public struct LastCheck: Codable, Equatable, Sendable {
        public var checkedAt: Date
        public var outcome: Outcome

        public init(checkedAt: Date, outcome: Outcome) {
            self.checkedAt = checkedAt
            self.outcome = outcome
        }
    }

    public enum Outcome: String, Codable, Equatable, Sendable {
        case upToDate
        case found
        case staged
        case failed
    }
}

public struct DeferredInstallIntent: Equatable, Sendable {
    public var version: String
    public var requestedAt: Date

    public init(version: String, requestedAt: Date) {
        self.version = version
        self.requestedAt = requestedAt
    }
}
