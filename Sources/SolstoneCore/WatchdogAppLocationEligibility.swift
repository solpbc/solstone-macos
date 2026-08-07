// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum WatchdogAppLocationEligibility {
    public static func isEligible(
        enclosingAppURL: URL,
        cachesURL: URL,
        temporaryDirectoryURL: URL
    ) -> Bool {
        let appURL = normalized(enclosingAppURL)
        let cachesURL = normalized(cachesURL)
        let temporaryDirectoryURL = normalized(temporaryDirectoryURL)

        guard !isContained(appURL, by: cachesURL),
              !isContained(appURL, by: temporaryDirectoryURL) else {
            return false
        }

        // Deliberately duplicated rather than extracted from the stricter app placement gate.
        // Unifying the predicates would require editing this frozen core target.
        // The app may reject locations this supervisor eligibility predicate permits.
        return !appURL.pathComponents.contains("AppTranslocation")
    }

    public static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isContained(_ candidate: URL, by container: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let containerComponents = container.pathComponents
        guard candidateComponents.count > containerComponents.count else { return false }
        return candidateComponents.starts(with: containerComponents)
    }
}
