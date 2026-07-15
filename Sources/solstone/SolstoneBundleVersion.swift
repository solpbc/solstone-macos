// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct SolstoneBundleVersion: Comparable, Equatable {
    let shortVersion: String
    let build: Int

    static func < (lhs: SolstoneBundleVersion, rhs: SolstoneBundleVersion) -> Bool {
        lhs.build < rhs.build
    }
}

enum SolstoneBundleVersionError: Error, Equatable {
    case bundleUnavailable
    case missingShortVersion
    case missingBuild
    case nonIntegerBuild(String)
}

enum SolstoneBundleVersionReader {
    static func read(fromBundleAt url: URL) throws -> SolstoneBundleVersion {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else {
            throw SolstoneBundleVersionError.bundleUnavailable
        }
        guard let shortVersion = info["CFBundleShortVersionString"] as? String, !shortVersion.isEmpty else {
            throw SolstoneBundleVersionError.missingShortVersion
        }
        guard let buildString = info["CFBundleVersion"] as? String, !buildString.isEmpty else {
            throw SolstoneBundleVersionError.missingBuild
        }
        guard let build = Int(buildString) else {
            throw SolstoneBundleVersionError.nonIntegerBuild(buildString)
        }
        return SolstoneBundleVersion(shortVersion: shortVersion, build: build)
    }
}
