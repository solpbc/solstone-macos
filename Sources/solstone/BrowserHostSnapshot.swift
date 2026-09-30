// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import Observation

public enum BrowserBrand: String, CaseIterable, Hashable, Sendable {
    case chrome
    case edge
    case firefox
}

public enum BrowserHostHandshake: Sendable, Equatable {
    case compatible
    case unsupportedApp
    case unsupportedExtension
    case unknown
}

public enum BrowserHostRegistrationState: String, Sendable, Equatable {
    case ready
    case changed
    case refused
    case unknown
}

public enum BrowserHostListenerState: Sendable, Equatable {
    case available
    case unavailable
    case collision
    case pathTooLong
}

public struct BrowserHostProfile: Sendable, Equatable {
    public let lastSeen: Date?
    public let handshake: BrowserHostHandshake
    public let byeReason: String?
    public let leaseExpiry: Date?

    public init(lastSeen: Date?, handshake: BrowserHostHandshake, byeReason: String?, leaseExpiry: Date?) {
        self.lastSeen = lastSeen
        self.handshake = handshake
        self.byeReason = byeReason
        self.leaseExpiry = leaseExpiry
    }
}

public struct BrowserHostProfileGroup: Sendable, Equatable {
    public let chrome: [BrowserHostProfile]
    public let edge: [BrowserHostProfile]
    public let firefox: [BrowserHostProfile]

    public init(chrome: [BrowserHostProfile] = [], edge: [BrowserHostProfile] = [], firefox: [BrowserHostProfile] = []) {
        self.chrome = chrome
        self.edge = edge
        self.firefox = firefox
    }
}

public struct BrowserHostRegistrationSummary: Sendable, Equatable {
    public let state: BrowserHostRegistrationState
    public let reasonCode: String?

    public init(state: BrowserHostRegistrationState, reasonCode: String? = nil) {
        self.state = state
        self.reasonCode = reasonCode
    }
}

public struct BrowserHostSnapshotValue: Sendable, Equatable {
    public var intakeEnabled: Bool
    public var capture: String
    public var delivery: String
    public var failureCode: String?
    public var custodyFull: Bool
    public var custodyStale: Bool
    public var custodyPresent: Bool
    public var profiles: BrowserHostProfileGroup
    public var registration: [BrowserBrand: BrowserHostRegistrationSummary]
    public var listener: BrowserHostListenerState
    public var shutdown: Bool
    public var quiescence: Bool

    public init(
        intakeEnabled: Bool = true,
        capture: String = "unavailable",
        delivery: String = "unknown",
        failureCode: String? = nil,
        custodyFull: Bool = false,
        custodyStale: Bool = false,
        custodyPresent: Bool = false,
        profiles: BrowserHostProfileGroup = BrowserHostProfileGroup(),
        registration: [BrowserBrand: BrowserHostRegistrationSummary] = [:],
        listener: BrowserHostListenerState = .unavailable,
        shutdown: Bool = false,
        quiescence: Bool = false
    ) {
        self.intakeEnabled = intakeEnabled
        self.capture = capture
        self.delivery = delivery
        self.failureCode = failureCode
        self.custodyFull = custodyFull
        self.custodyStale = custodyStale
        self.custodyPresent = custodyPresent
        self.profiles = profiles
        self.registration = registration
        self.listener = listener
        self.shutdown = shutdown
        self.quiescence = quiescence
    }
}

public struct BrowserHostOwnerFacts: Sendable {
    public var intakeEnabled: Bool
    public var capture: String
    public var delivery: String
    public var failureCode: String?
    public var custodyFull: Bool
    public var custodyStale: Bool
    public var custodyPresent: Bool
    public var destinationGeneration: String?
    public var periodId: String?

    public init(status: [String: Any], intakeEnabled: Bool) {
        let custody = status["custody"] as? [String: Any]
        self.intakeEnabled = intakeEnabled
        capture = status["capture"] as? String ?? "unavailable"
        delivery = status["delivery"] as? String ?? "unknown"
        failureCode = status["failure"] as? String
        custodyFull = custody?["full"] as? Bool ?? false
        custodyStale = custody?["stale"] as? Bool ?? false
        custodyPresent = custody != nil
        destinationGeneration = status["destination_generation"] as? String
        periodId = status["period_id"] as? String
    }
}

public enum BrowserHostSnapshotProjection {
    public static func fromOwnerStatus(
        _ status: [String: Any],
        intakeEnabled: Bool,
        profiles: BrowserHostProfileGroup = BrowserHostProfileGroup(),
        registration: [BrowserBrand: BrowserHostRegistrationSummary] = [:],
        listener: BrowserHostListenerState = .unavailable,
        shutdown: Bool = false,
        quiescence: Bool = false
    ) -> BrowserHostSnapshotValue {
        let custody = status["custody"] as? [String: Any]
        return BrowserHostSnapshotValue(
            intakeEnabled: intakeEnabled,
            capture: status["capture"] as? String ?? "unavailable",
            delivery: status["delivery"] as? String ?? "unknown",
            failureCode: status["failure"] as? String,
            custodyFull: custody?["full"] as? Bool ?? false,
            custodyStale: custody?["stale"] as? Bool ?? false,
            custodyPresent: custody != nil,
            profiles: profiles,
            registration: registration,
            listener: listener,
            shutdown: shutdown,
            quiescence: quiescence
        )
    }
}

@Observable
@MainActor
public final class BrowserHostSnapshot {
    public private(set) var value = BrowserHostSnapshotValue()

    public init() {}

    public func publish(_ value: BrowserHostSnapshotValue) {
        self.value = value
    }
}

#endif
