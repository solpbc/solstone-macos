import Foundation

enum InstallerCardState: Equatable {
    case detecting
    case absent
    case installing
    case installedPlaceholder
    case done
    case installedCurrent(version: String)
    case installedOutdated(installed: String, pinned: String)
    case installedUnknown
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
    case .installingSolstone, .runningSolSetup, .registering:
        return .installing
    case .done:
        return .done
    case .failed(let failedState):
        return .failed(failedState)
    }
}

func terminalCardState(main: MainState, probe: VersionProbeResult?) -> InstallerCardState {
    let intermediate = cardState(from: main)
    guard let probe else { return intermediate }
    switch intermediate {
    case .installedPlaceholder, .done:
        switch probe {
        case .current(let version):
            return .installedCurrent(version: version)
        case .outdated(let installed, let pinned):
            return .installedOutdated(installed: installed, pinned: pinned)
        case .unknown:
            return .installedUnknown
        }
    default:
        return intermediate
    }
}

func rowStatus(for row: InstallerRow, main: MainState, modelsProgress: ModelsProgress) -> RowStatus {
    switch row {
    case .checkingSystem:
        if case .detecting = main {
            return .running
        }
        return .ok
    case .installSolstone:
        switch main {
        case .detecting, .awaitingChoice:
            return .pending
        case .installingSolstone:
            return .running
        case .runningSolSetup, .registering, .done:
            return .ok
        case .failed(let failedState):
            if case .installSolstone(let message) = failedState {
                return .failed(message: message)
            }
            return .ok
        }
    case .solSetup:
        switch main {
        case .detecting, .awaitingChoice, .installingSolstone:
            return .pending
        case .runningSolSetup:
            return .running
        case .registering, .done:
            return .ok
        case .failed(let failedState):
            switch failedState {
            case .solSetup(_, let message):
                return .failed(message: message)
            case .installSolstone:
                return .pending
            case .registering, .installModels:
                return .ok
            }
        }
    case .registering:
        switch main {
        case .detecting, .awaitingChoice, .installingSolstone, .runningSolSetup:
            return .pending
        case .registering:
            return .running
        case .done:
            return .ok
        case .failed(let failedState):
            switch failedState {
            case .registering(let message):
                return .failed(message: message)
            case .installSolstone, .solSetup:
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
