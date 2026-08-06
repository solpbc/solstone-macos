// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum WatchdogStateCause: String, Codable, Equatable, Sendable {
    case noEnclosingApp = "no-enclosing-app"
    // Restore-in-progress and updater mid-replacement are intentionally not separated: no reliable API distinguishes them and both should retry.
    case infoPlistUnreadable = "info-plist-unreadable"
    case infoPlistMalformed = "info-plist-malformed"
    case nonLocalVolume = "non-local-volume"
    case unsupportedBundleIdentifier = "unsupported-bundle-identifier"
    case ineligibleLocation = "ineligible-location"
    case conflictingCopy = "conflicting-copy"
}

public struct WatchdogIdentity: Equatable, Sendable {
    public let product: WatchdogProduct
    public let enclosingBundleURL: URL
    public let enclosingBundleIdentifier: String
    public let writerExecutableURL: URL

    public init(
        product: WatchdogProduct,
        enclosingBundleURL: URL,
        enclosingBundleIdentifier: String,
        writerExecutableURL: URL
    ) {
        self.product = product
        self.enclosingBundleURL = enclosingBundleURL
        self.enclosingBundleIdentifier = enclosingBundleIdentifier
        self.writerExecutableURL = writerExecutableURL
    }
}

public struct WatchdogRefusal: Equatable, Sendable {
    public let cause: WatchdogStateCause
    public let enclosingBundleURL: URL?
    public let enclosingBundleIdentifier: String?
    public let writerExecutableURL: URL

    public init(
        cause: WatchdogStateCause,
        enclosingBundleURL: URL?,
        enclosingBundleIdentifier: String?,
        writerExecutableURL: URL
    ) {
        self.cause = cause
        self.enclosingBundleURL = enclosingBundleURL
        self.enclosingBundleIdentifier = enclosingBundleIdentifier
        self.writerExecutableURL = writerExecutableURL
    }
}

public enum WatchdogIdentityResolution: Equatable, Sendable {
    case resolved(WatchdogIdentity)
    case permanentRefusal(WatchdogRefusal)
    case transientRefusal(WatchdogRefusal)
}

public enum WatchdogIdentityResolver {
    public static func resolve(
        writerExecutableURL: URL,
        cachesURL: URL,
        temporaryDirectoryURL: URL,
        volumeIsLocal: (URL) -> Bool?
    ) -> WatchdogIdentityResolution {
        guard let enclosingBundleURL = enclosingAppURL(from: writerExecutableURL) else {
            return .permanentRefusal(refusal(
                cause: .noEnclosingApp,
                bundleURL: nil,
                bundleIdentifier: nil,
                writerExecutableURL: writerExecutableURL
            ))
        }

        if volumeIsLocal(enclosingBundleURL) == false {
            return .transientRefusal(refusal(
                cause: .nonLocalVolume,
                bundleURL: enclosingBundleURL,
                bundleIdentifier: nil,
                writerExecutableURL: writerExecutableURL
            ))
        }

        let info: WatchdogBundleInfo
        do {
            info = try WatchdogBundleInfoReader.read(fromEnclosingBundleAt: enclosingBundleURL)
        } catch let error as WatchdogBundleInfoReadError {
            let cause: WatchdogStateCause = switch error {
            case .infoPlistUnreadable: .infoPlistUnreadable
            case .infoPlistMalformed: .infoPlistMalformed
            }
            return .transientRefusal(refusal(
                cause: cause,
                bundleURL: enclosingBundleURL,
                bundleIdentifier: nil,
                writerExecutableURL: writerExecutableURL
            ))
        } catch {
            return .transientRefusal(refusal(
                cause: .infoPlistUnreadable,
                bundleURL: enclosingBundleURL,
                bundleIdentifier: nil,
                writerExecutableURL: writerExecutableURL
            ))
        }

        guard let product = WatchdogProduct(enclosingBundleIdentifier: info.bundleIdentifier) else {
            return .permanentRefusal(refusal(
                cause: .unsupportedBundleIdentifier,
                bundleURL: enclosingBundleURL,
                bundleIdentifier: info.bundleIdentifier,
                writerExecutableURL: writerExecutableURL
            ))
        }

        guard WatchdogAppLocationEligibility.isEligible(
            enclosingAppURL: enclosingBundleURL,
            cachesURL: cachesURL,
            temporaryDirectoryURL: temporaryDirectoryURL
        ) else {
            return .permanentRefusal(refusal(
                cause: .ineligibleLocation,
                bundleURL: enclosingBundleURL,
                bundleIdentifier: info.bundleIdentifier,
                writerExecutableURL: writerExecutableURL
            ))
        }

        return .resolved(WatchdogIdentity(
            product: product,
            enclosingBundleURL: enclosingBundleURL,
            enclosingBundleIdentifier: info.bundleIdentifier,
            writerExecutableURL: writerExecutableURL
        ))
    }

    private static func refusal(
        cause: WatchdogStateCause,
        bundleURL: URL?,
        bundleIdentifier: String?,
        writerExecutableURL: URL
    ) -> WatchdogRefusal {
        WatchdogRefusal(
            cause: cause,
            enclosingBundleURL: bundleURL,
            enclosingBundleIdentifier: bundleIdentifier,
            writerExecutableURL: writerExecutableURL
        )
    }
}
