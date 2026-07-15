// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

enum AppPlacementAllowedReason: Equatable {
    case canonical
    case developerBypass
}

struct AppPlacementContext: Equatable {
    let runningBundleURL: URL
    let canonicalBundleURL: URL
    let applicationsURL: URL
    let runningStandardizedURL: URL
    let runningResolvedURL: URL
    let canonicalStandardizedURL: URL
    let canonicalResolvedURL: URL
    let pathLooksTranslocated: Bool
}

enum AppPlacementDecision: Equatable {
    case allowed(AppPlacementAllowedReason)
    case repair(AppPlacementContext)
}

enum AppPlacementDiagnostic: Equatable {
    case appTranslocationPathObserved(String)
}

enum AppPlacementGate {
    static let developerLaunchEnvironmentKey = "SOLSTONE_DEV_LAUNCH"
    static let canonicalBundleName = "solstone.app"

    struct Dependencies {
        var bundleURL: URL
        var environment: [String: String]
        var applicationsURL: URL
        var log: (AppPlacementDiagnostic) -> Void

        init(
            bundleURL: URL = Bundle.main.bundleURL,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            applicationsURL: URL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)[0],
            log: @escaping (AppPlacementDiagnostic) -> Void = { diagnostic in
                switch diagnostic {
                case .appTranslocationPathObserved(let path):
                    Logger.setup.warning("bundle path contains AppTranslocation diagnostic segment: \(path, privacy: .public)")
                }
            }
        ) {
            self.bundleURL = bundleURL
            self.environment = environment
            self.applicationsURL = applicationsURL
            self.log = log
        }
    }

    static func evaluate(dependencies: Dependencies = Dependencies()) -> AppPlacementDecision {
        let canonicalBundleURL = dependencies.applicationsURL
            .appendingPathComponent(canonicalBundleName, isDirectory: true)
        let runningStandardizedURL = dependencies.bundleURL.standardizedFileURL
        let runningResolvedURL = runningStandardizedURL.resolvingSymlinksInPath()
        let canonicalStandardizedURL = canonicalBundleURL.standardizedFileURL
        let canonicalResolvedURL = canonicalStandardizedURL.resolvingSymlinksInPath()
        let pathLooksTranslocated = dependencies.bundleURL.path.contains("/AppTranslocation/")

        if pathLooksTranslocated {
            dependencies.log(.appTranslocationPathObserved(dependencies.bundleURL.path))
        }

        let context = AppPlacementContext(
            runningBundleURL: dependencies.bundleURL,
            canonicalBundleURL: canonicalBundleURL,
            applicationsURL: dependencies.applicationsURL,
            runningStandardizedURL: runningStandardizedURL,
            runningResolvedURL: runningResolvedURL,
            canonicalStandardizedURL: canonicalStandardizedURL,
            canonicalResolvedURL: canonicalResolvedURL,
            pathLooksTranslocated: pathLooksTranslocated
        )

        if isCanonical(context) {
            return .allowed(.canonical)
        }

        if dependencies.environment[developerLaunchEnvironmentKey] == "1" {
            return .allowed(.developerBypass)
        }

        return .repair(context)
    }

    private static func isCanonical(_ context: AppPlacementContext) -> Bool {
        context.canonicalStandardizedURL.path == context.canonicalResolvedURL.path
            && context.runningStandardizedURL.path == context.canonicalStandardizedURL.path
            && context.runningResolvedURL.path == context.canonicalResolvedURL.path
    }
}

enum SolstoneStartupMode: Equatable {
    case normal(AppPlacementAllowedReason)
    case repair(AppPlacementContext)
}

enum SolstoneStartupPlanner {
    static func mode(for decision: AppPlacementDecision) -> SolstoneStartupMode {
        switch decision {
        case .allowed(let reason):
            return .normal(reason)
        case .repair(let context):
            return .repair(context)
        }
    }

    @MainActor
    static func planStartup<Normal>(
        decision: AppPlacementDecision,
        coordinator: AppPlacementRepairCoordinator = .shared,
        makeNormal: () -> Normal
    ) -> Normal? {
        switch mode(for: decision) {
        case .normal:
            return makeNormal()
        case .repair(let context):
            coordinator.registerRepair(context: context)
            return nil
        }
    }
}
