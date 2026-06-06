import Foundation

/// Update state has two layers:
///
/// - `ReconciledUpdateStatus` is the durable fact persisted across launches. It
///   remembers the latest version Sparkle found and the most recent check
///   outcome. A found result sets `availableVersion`, a definitive up-to-date
///   result clears it, and a failed check preserves it.
/// - `UpdateActivity` is only live Sparkle activity. It must not be restored
///   from disk because downloading, extraction, ready-to-install, and installing
///   states are backed by Sparkle replies or sessions that only exist in memory.
///
/// On launch, a persisted available version equal to the running bundle display
/// version is reconciled to up-to-date and cleared. Any other persisted version
/// remains available and is surfaced with a download affordance; if no live
/// Sparkle reply exists, the download starts a user-initiated check to rehydrate
/// the callback and then auto-continues with the install.
struct AvailableUpdate: Equatable, Sendable {
    var version: String
    var releaseNotes: String?
}

enum UpdateActivity: Equatable, Sendable {
    case idle
    case checking
    case downloading(version: String, receivedBytes: UInt64, totalBytes: UInt64?)
    case extracting(version: String, progress: Double)
    case readyToInstall(version: String, releaseNotes: String?)
    case installing(version: String)
}

struct ReconciledUpdateStatus: Codable, Equatable, Sendable {
    var availableVersion: String?
    var lastCheck: LastCheck?

    init(availableVersion: String? = nil, lastCheck: LastCheck? = nil) {
        self.availableVersion = availableVersion
        self.lastCheck = lastCheck
    }

    struct LastCheck: Codable, Equatable, Sendable {
        var checkedAt: Date
        var outcome: Outcome

        init(checkedAt: Date, outcome: Outcome) {
            self.checkedAt = checkedAt
            self.outcome = outcome
        }
    }

    enum Outcome: String, Codable, Equatable, Sendable {
        case upToDate
        case found
        case failed
    }
}

struct DeferredInstallIntent: Equatable, Sendable {
    var version: String
    var requestedAt: Date
}
