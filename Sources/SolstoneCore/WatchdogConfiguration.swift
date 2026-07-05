// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct WatchdogConfiguration: Equatable, Sendable {
    public static let targetBundleIDEnvironmentKey = "SOLSTONE_WATCHDOG_TARGET_BUNDLE_ID"
    public static let loggerSubsystemEnvironmentKey = "SOLSTONE_WATCHDOG_LOGGER_SUBSYSTEM"
    public static let markerDiscriminatorEnvironmentKey = "SOLSTONE_WATCHDOG_MARKER_DISCRIMINATOR"

    public static let defaultTargetBundleID = SolstoneIdentity.bundleIdentifier
    public static let defaultLoggerSubsystem = "app.solstone.observer.watchdog"
    public static let defaultMarkerDiscriminator = ExpectedExitMarker.solMarkerDiscriminator

    public let targetBundleID: String
    public let loggerSubsystem: String
    public let markerDiscriminator: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        targetBundleID = Self.value(
            for: Self.targetBundleIDEnvironmentKey,
            in: environment,
            defaultValue: Self.defaultTargetBundleID
        )
        loggerSubsystem = Self.value(
            for: Self.loggerSubsystemEnvironmentKey,
            in: environment,
            defaultValue: Self.defaultLoggerSubsystem
        )
        markerDiscriminator = Self.value(
            for: Self.markerDiscriminatorEnvironmentKey,
            in: environment,
            defaultValue: Self.defaultMarkerDiscriminator
        )
    }

    public var markerURL: URL {
        ExpectedExitMarker.markerURL(for: markerDiscriminator)
    }

    private static func value(
        for key: String,
        in environment: [String: String],
        defaultValue: String
    ) -> String {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return defaultValue
        }
        return value
    }
}
