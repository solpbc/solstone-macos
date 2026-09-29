// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation

public struct NativeHostAllowlist: Sendable, Equatable {
    public struct ModeIDs: Sendable, Equatable {
        public let chrome: String
        public let edge: String
        public let firefox: String

        public init(chrome: String, edge: String, firefox: String) {
            self.chrome = chrome
            self.edge = edge
            self.firefox = firefox
        }
    }

    public let production: ModeIDs
    public let development: ModeIDs

    public init(production: ModeIDs, development: ModeIDs) {
        self.production = production
        self.development = development
    }

    public init(authorityJSON: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: authorityJSON) as? [String: Any],
              let hosts = root["hosts_and_ids"] as? [String: Any],
              let production = Self.ids(hosts["production"]),
              let development = Self.ids(hosts["dev"]) else {
            throw NativeHostArgvError.invalidContract
        }
        self.init(production: production, development: development)
    }

    private static func ids(_ value: Any?) -> ModeIDs? {
        guard let object = value as? [String: Any],
              let chrome = object["chrome_id"] as? String,
              let edge = object["edge_id"] as? String,
              let firefox = object["firefox_id"] as? String else { return nil }
        return ModeIDs(chrome: chrome, edge: edge, firefox: firefox)
    }
}

public enum NativeHostBrandHint: String, Sendable, Equatable {
    case chromium
    case firefox
}

public enum NativeHostMode: String, Sendable, Equatable {
    case production
    case development
}

public struct NativeHostIdentity: Sendable, Equatable {
    public let brandHint: NativeHostBrandHint
    public let mode: NativeHostMode

    public init(brandHint: NativeHostBrandHint, mode: NativeHostMode) {
        self.brandHint = brandHint
        self.mode = mode
    }
}

public enum NativeHostArgvError: Error, Equatable, Sendable {
    case rejected
    case invalidContract
}

public enum NativeHostArgv {
    /// A well-formed allowed identity is not caller authentication; same-user spoofing is outside this claim.
    public static func parse(_ arguments: [String], allowlist: NativeHostAllowlist) throws -> NativeHostIdentity {
        guard !arguments.contains("parent_window") else { throw NativeHostArgvError.rejected }
        if arguments.count == 1,
           let origin = arguments.first,
           origin.hasPrefix("chrome-extension://"),
           origin.hasSuffix("/") {
            let productionIDs = Set([allowlist.production.chrome, allowlist.production.edge])
            let developmentIDs = Set([allowlist.development.chrome, allowlist.development.edge])
            let prodMatches = productionIDs.contains(where: { origin == "chrome-extension://\($0)/" })
            let devMatches = developmentIDs.contains(where: { origin == "chrome-extension://\($0)/" })
            if prodMatches != devMatches {
                return NativeHostIdentity(brandHint: .chromium, mode: prodMatches ? .production : .development)
            }
            throw NativeHostArgvError.rejected
        }

        if arguments.count == 2 {
            guard !arguments[0].hasPrefix("chrome-extension://"), !arguments[0].isEmpty else {
                throw NativeHostArgvError.rejected
            }
            let extensionID = arguments[1]
            let prodMatches = extensionID == allowlist.production.firefox
            let devMatches = extensionID == allowlist.development.firefox
            if prodMatches != devMatches {
                return NativeHostIdentity(brandHint: .firefox, mode: prodMatches ? .production : .development)
            }
        }
        throw NativeHostArgvError.rejected
    }
}

public enum NativeHostRelayEvent: Sendable, Equatable {
    case stdinEOF
    case sigterm
    case hostBye
    case hostUnsupported
    case appLoss
    case forwardFailure
    case hostAccepted
    case extensionFrame
}

public enum NativeHostRelayEffect: Sendable, Equatable {
    case forwardToApp
    case forwardToExtension
    case stop
}

public struct NativeHostRelayReducer: Sendable {
    public private(set) var forwardedAcceptance = false
    private var terminal = false

    public init() {}

    public mutating func reduce(_ event: NativeHostRelayEvent) -> NativeHostRelayEffect {
        guard !terminal else { return .stop }
        switch event {
        case .stdinEOF, .sigterm, .hostBye, .hostUnsupported, .appLoss, .forwardFailure:
            terminal = true
            return .stop
        case .hostAccepted:
            forwardedAcceptance = true
            return .forwardToExtension
        case .extensionFrame:
            return .forwardToApp
        }
    }
}

#endif
