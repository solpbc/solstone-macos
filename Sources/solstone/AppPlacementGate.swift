// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

enum AppPlacementAllowedReason: Equatable {
    case canonical
    case stableLocation
    case developerBypass
}

struct AppPlacementContext: Equatable {
    let runningBundleURL: URL
    let canonicalBundleURL: URL
    let applicationsURL: URL
}

enum AppPlacementDecision: Equatable {
    case allowed(AppPlacementAllowedReason)
    case repair(AppPlacementContext)
}

enum AppPlacementDiagnostic: Equatable {
    case appTranslocationPathObserved(String)
}

struct AppPlacementVolumeFacts: Equatable {
    let isInternal: Bool?
    let isLocal: Bool?
}

enum AppPlacementGate {
    static let developerLaunchEnvironmentKey = "SOLSTONE_DEV_LAUNCH"
    static let canonicalBundleName = "solstone.app"

    struct Dependencies {
        var bundleURL: URL
        var environment: [String: String]
        var applicationsURL: URL
        var cachesURL: URL
        var temporaryDirectoryURL: URL
        var volumeFacts: (URL) -> AppPlacementVolumeFacts?
        var log: (AppPlacementDiagnostic) -> Void

        init(
            bundleURL: URL = Bundle.main.bundleURL,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            applicationsURL: URL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)[0],
            // Placement must exclude the current user's cache root, not /Library/Caches.
            cachesURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
            temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
            volumeFacts: @escaping (URL) -> AppPlacementVolumeFacts? = { url in
                do {
                    let values = try url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
                    return AppPlacementVolumeFacts(
                        isInternal: values.volumeIsInternal,
                        isLocal: values.volumeIsLocal
                    )
                } catch {
                    return nil
                }
            },
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
            self.cachesURL = cachesURL
            self.temporaryDirectoryURL = temporaryDirectoryURL
            self.volumeFacts = volumeFacts
            self.log = log
        }
    }

    static func evaluate(dependencies: Dependencies = Dependencies()) -> AppPlacementDecision {
        let canonicalBundleURL = dependencies.applicationsURL
            .appendingPathComponent(canonicalBundleName, isDirectory: true)
        let runningResolvedURL = normalized(dependencies.bundleURL)
        let canonicalResolvedURL = normalized(canonicalBundleURL)
        let isTranslocated = runningResolvedURL.pathComponents.contains("AppTranslocation")

        if isTranslocated {
            dependencies.log(.appTranslocationPathObserved(dependencies.bundleURL.path))
        }

        let context = AppPlacementContext(
            runningBundleURL: dependencies.bundleURL,
            canonicalBundleURL: canonicalBundleURL,
            applicationsURL: dependencies.applicationsURL
        )

        if isStable(
            runningResolvedURL: runningResolvedURL,
            cachesURL: dependencies.cachesURL,
            temporaryDirectoryURL: dependencies.temporaryDirectoryURL,
            isTranslocated: isTranslocated,
            volumeFacts: dependencies.volumeFacts(runningResolvedURL)
        ) {
            return .allowed(
                runningResolvedURL == canonicalResolvedURL ? .canonical : .stableLocation
            )
        }

        if dependencies.environment[developerLaunchEnvironmentKey] == "1" {
            return .allowed(.developerBypass)
        }

        return .repair(context)
    }

    private static func isStable(
        runningResolvedURL: URL,
        cachesURL: URL,
        temporaryDirectoryURL: URL,
        isTranslocated: Bool,
        volumeFacts: AppPlacementVolumeFacts?
    ) -> Bool {
        guard !isTranslocated,
              !isContained(runningResolvedURL, by: normalized(cachesURL)),
              !isContained(runningResolvedURL, by: normalized(temporaryDirectoryURL)),
              !isContained(runningResolvedURL, by: normalized(URL(fileURLWithPath: "/private/tmp", isDirectory: true))),
              !isContained(runningResolvedURL, by: normalized(URL(fileURLWithPath: "/private/var/tmp", isDirectory: true))),
              volumeFacts?.isInternal == true,
              volumeFacts?.isLocal == true else {
            return false
        }
        return true
    }

    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isContained(_ candidate: URL, by container: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let containerComponents = container.pathComponents
        guard candidateComponents.count > containerComponents.count else { return false }
        return candidateComponents.starts(with: containerComponents)
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
