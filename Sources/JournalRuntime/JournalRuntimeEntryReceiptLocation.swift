// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

public enum JournalRuntimeEntryLocationClassifier {
    public struct VolumeFacts: Sendable {
        public let isInternal: Bool?
        public let isLocal: Bool?

        public init(isInternal: Bool?, isLocal: Bool?) {
            self.isInternal = isInternal
            self.isLocal = isLocal
        }
    }

    public struct Dependencies: Sendable {
        public let cachesURL: URL
        public let temporaryDirectoryURL: URL
        public let volumeFacts: @Sendable (URL) -> VolumeFacts?

        public init(
            cachesURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
            temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
            volumeFacts: @escaping @Sendable (URL) -> VolumeFacts? = { url in
                guard let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey]) else {
                    return nil
                }
                return VolumeFacts(isInternal: values.volumeIsInternal, isLocal: values.volumeIsLocal)
            }
        ) {
            self.cachesURL = cachesURL
            self.temporaryDirectoryURL = temporaryDirectoryURL
            self.volumeFacts = volumeFacts
        }
    }

    public static func classify(
        bundleURL: URL,
        dependencies: Dependencies = Dependencies()
    ) -> JournalRuntimeEntryLocationClass {
        let resolved = WatchdogAppLocationEligibility.normalized(bundleURL)
        if resolved.pathComponents.contains("AppTranslocation") {
            return .translocated
        }

        let rejectedRoots = [
            dependencies.cachesURL,
            dependencies.temporaryDirectoryURL,
            URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
        ].map(WatchdogAppLocationEligibility.normalized)
        guard !rejectedRoots.contains(where: { isContained(resolved, by: $0) }),
              let facts = dependencies.volumeFacts(resolved),
              facts.isInternal == true,
              facts.isLocal == true else {
            return .other
        }
        return .standard
    }

    private static func isContained(_ candidate: URL, by container: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let containerComponents = container.pathComponents
        guard candidateComponents.count > containerComponents.count else { return false }
        return candidateComponents.starts(with: containerComponents)
    }
}
