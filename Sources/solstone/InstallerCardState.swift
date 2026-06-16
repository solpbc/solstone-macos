import Foundation
import SolstoneCore

enum InstallerCardState: Equatable {
    case detecting
    case absent
    case installing
    case installedPlaceholder
    case done
    case installedCurrent(version: String)
    case installedUnknown
    case externallyManaged(solPath: String, probe: VersionProbeResult?)
    case runtimeStarting
    case runtimeFailed(JournalRuntimeStatus)
    case runtimeUnconfirmed
    case runtimeStoppedByUser
    case upgradeFailed(installed: String?, pinned: String, errorDetails: String)
    case failed(FailedState)
}

public enum VersionProbeResult: Equatable, Sendable {
    case current(version: String)
    case outdated(installed: String, pinned: String)
    case unknown
}

public enum AutoTestState: Equatable, Sendable {
    case verifying
    case success
    case failure(String)
}

enum RowStatus: Equatable {
    case pending
    case running
    case ok
    case failed(message: String)
}

enum InstallerRow: String, CaseIterable {
    case checkingSystem = "row.checkingSystem"
    case cleaningUp = "row.cleaningUp"
    case installSolstone = "row.installSolstone"
    case solSetup = "row.solSetup"
    case registering = "row.registering"
    case models = "row.models"
}

func cardState(from main: MainState) -> InstallerCardState {
    switch main {
    case .detecting:
        return .detecting
    case .awaitingChoice(let existingInstall):
        return existingInstall ? .installedPlaceholder : .absent
    case .cleaningUp, .installingSolstone, .runningSolSetup, .registering:
        return .installing
    case .externallyManaged(let solPath):
        return .externallyManaged(solPath: solPath, probe: nil)
    case .done:
        return .done
    case .failed(let failedState):
        return .failed(failedState)
    }
}

func terminalCardState(
    main: MainState,
    probe: VersionProbeResult?,
    failureRecord: UpgradeFailureRecord?
) -> InstallerCardState {
    let intermediate = cardState(from: main)
    if case .externallyManaged(let solPath, _) = intermediate {
        return .externallyManaged(solPath: solPath, probe: probe)
    }
    if case .failed = intermediate {
        if let failureRecord, failureRecord.pinned == BundleConfig.solstonePinVersion {
            return .upgradeFailed(
                installed: failureRecord.installed,
                pinned: failureRecord.pinned,
                errorDetails: failureRecord.errorDetails
            )
        }
        return intermediate
    }
    guard let probe else { return intermediate }
    switch intermediate {
    case .installedPlaceholder, .done:
        switch probe {
        case .current(let version):
            return .installedCurrent(version: version)
        case .outdated:
            if let failureRecord, failureRecord.pinned == BundleConfig.solstonePinVersion {
                return .upgradeFailed(
                    installed: failureRecord.installed,
                    pinned: failureRecord.pinned,
                    errorDetails: failureRecord.errorDetails
                )
            }
            return .installing
        case .unknown:
            return .installedUnknown
        }
    default:
        return intermediate
    }
}

func bundledJournalCardState(
    main: MainState,
    failureRecord: UpgradeFailureRecord?,
    runtimeStatus: JournalRuntimeStatus,
    startInFlight: Bool,
    confirmedAtPin: Bool
) -> InstallerCardState {
    let intermediate = cardState(from: main)
    if case .externallyManaged(let solPath, _) = intermediate {
        return .externallyManaged(solPath: solPath, probe: nil)
    }
    if case .failed = intermediate {
        if let failureRecord, failureRecord.pinned == BundleConfig.solstonePinVersion {
            return .upgradeFailed(
                installed: failureRecord.installed,
                pinned: failureRecord.pinned,
                errorDetails: failureRecord.errorDetails
            )
        }
        return intermediate
    }

    switch intermediate {
    case .installedPlaceholder, .done:
        if startInFlight {
            return .runtimeStarting
        }
        if confirmedAtPin {
            return .installedCurrent(version: BundleConfig.solstonePinVersion)
        }
        switch runtimeStatus {
        case .running:
            return .runtimeUnconfirmed
        case .restarting:
            return .runtimeStarting
        case .stopped, .unknown, .setupNeeded:
            return .runtimeFailed(runtimeStatus)
        case .stoppedByUser:
            return .runtimeStoppedByUser
        }
    default:
        return intermediate
    }
}

/// Pinned contract: mode controls render in every installer state.
/// Retained as the unit-testable seam asserting that behavior.
func shouldCompressServiceModeControls(mode: ServiceMode, cardState: InstallerCardState) -> Bool {
    false
}

/// Whether the bundled install surface (progress or failure) should stay
/// observable regardless of which journal mode is selected in the picker.
/// `.detecting` is transient and not attention-worthy, so it is excluded.
func shouldShowBundledStatusSurface(cardState: InstallerCardState) -> Bool {
    switch cardState {
    case .installing, .failed, .upgradeFailed:
        return true
    case .detecting,
         .absent,
         .installedPlaceholder,
         .done,
         .installedCurrent,
         .installedUnknown,
         .externallyManaged,
         .runtimeStarting,
         .runtimeFailed,
         .runtimeUnconfirmed,
         .runtimeStoppedByUser:
        return false
    }
}

func rowStatus(for row: InstallerRow, main: MainState, modelsProgress: ModelsProgress) -> RowStatus {
    switch row {
    case .checkingSystem:
        if case .detecting = main {
            return .running
        }
        return .ok
    case .cleaningUp:
        switch main {
        case .detecting, .awaitingChoice, .externallyManaged:
            return .pending
        case .cleaningUp:
            return .running
        case .installingSolstone, .runningSolSetup, .registering, .done:
            return .ok
        case .failed(let failedState):
            if case .cleanup(_, let message) = failedState {
                return .failed(message: message)
            }
            return .ok
        }
    case .installSolstone:
        switch main {
        case .detecting, .awaitingChoice, .cleaningUp, .externallyManaged:
            return .pending
        case .installingSolstone:
            return .running
        case .runningSolSetup, .registering, .done:
            return .ok
        case .failed(let failedState):
            switch failedState {
            case .installSolstone(let message):
                return .failed(message: message)
            case .cleanup:
                return .pending
            case .upgradeCutoverFailed(let message):
                return .failed(message: message)
            default:
                return .ok
            }
        }
    case .solSetup:
        switch main {
        case .detecting, .awaitingChoice, .cleaningUp, .installingSolstone, .externallyManaged:
            return .pending
        case .runningSolSetup:
            return .running
        case .registering, .done:
            return .ok
        case .failed(let failedState):
            switch failedState {
            case .solSetup(_, let message):
                return .failed(message: message)
            case .cleanup, .installSolstone:
                return .pending
            case .registering, .installModels, .upgradeCutoverFailed:
                return .ok
            }
        }
    case .registering:
        switch main {
        case .detecting, .awaitingChoice, .cleaningUp, .installingSolstone, .runningSolSetup, .externallyManaged:
            return .pending
        case .registering:
            return .running
        case .done:
            return .ok
        case .failed(let failedState):
            switch failedState {
            case .registering(let message):
                return .failed(message: message)
            case .cleanup, .installSolstone, .solSetup, .upgradeCutoverFailed:
                return .pending
            case .installModels:
                return .ok
            }
        }
    case .models:
        switch modelsProgress {
        case .idle:
            return .pending
        case .running:
            return .running
        case .done:
            return .ok
        case .failed(let message):
            return .failed(message: message)
        }
    }
}

func currentSubprocessProgress(
    for row: InstallerRow,
    main: MainState,
    modelsProgress: ModelsProgress
) -> SubprocessProgress? {
    switch row {
    case .checkingSystem:
        return nil
    case .cleaningUp:
        if case .cleaningUp(let progress) = main {
            return progress
        }
        return nil
    case .installSolstone:
        if case .installingSolstone(let progress) = main {
            return progress
        }
        return nil
    case .solSetup:
        if case .runningSolSetup(let progress) = main {
            return progress
        }
        return nil
    case .registering:
        if case .registering(let progress) = main {
            return progress
        }
        return nil
    case .models:
        if case .running(let progress) = modelsProgress {
            return progress
        }
        return nil
    }
}

func isJournalPathTccRestricted(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let home = (NSHomeDirectory() as NSString).standardizingPath
    let restrictedRoots = [
        home + "/Documents",
        home + "/Desktop",
        home + "/Downloads",
        "/Volumes"
    ]

    for root in restrictedRoots where path == root || path.hasPrefix(root + "/") {
        return true
    }
    return false
}

func isLogExpanded(for row: InstallerRow, in state: [String: Bool]) -> Bool {
    state[row.rawValue, default: false]
}
