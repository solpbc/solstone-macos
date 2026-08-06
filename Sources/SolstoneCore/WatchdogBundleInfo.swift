// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct WatchdogBundleInfo: Equatable, Sendable {
    public let bundleIdentifier: String
    public let shortVersion: String?
    public let buildVersion: String?

    public init(bundleIdentifier: String, shortVersion: String?, buildVersion: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
    }
}

public enum WatchdogBundleInfoReadError: Error, Equatable, Sendable {
    case infoPlistUnreadable
    case infoPlistMalformed
}

public enum WatchdogBundleInfoReader {
    public static func read(fromEnclosingBundleAt bundleURL: URL) throws -> WatchdogBundleInfo {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let data: Data
        do {
            data = try Data(contentsOf: infoPlistURL)
        } catch {
            throw WatchdogBundleInfoReadError.infoPlistUnreadable
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw WatchdogBundleInfoReadError.infoPlistMalformed
        }

        guard let dictionary = propertyList as? [String: Any],
              let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw WatchdogBundleInfoReadError.infoPlistMalformed
        }

        return WatchdogBundleInfo(
            bundleIdentifier: bundleIdentifier,
            shortVersion: nonEmptyString(dictionary["CFBundleShortVersionString"]),
            buildVersion: nonEmptyString(dictionary["CFBundleVersion"])
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}
