// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum JournalRelayAccessValidationError: Error, Equatable, Sendable {
    case invalidProtocolVersion
    case invalidStatus
    case instanceMismatch
    case invalidRelayOrigin
    case invalidRFC3339Expiry
    case expiredOrUnusable
    case expiryJWTExpMismatch
    case invalidJWTFormat
    case invalidJWTPayloadEncoding
    case invalidJWTPayloadJSON
    case unexpectedJWTClaims
    case invalidJWTVersion
    case invalidJWTAudience
    case invalidJWTScope
    case invalidJWTSubject
    case invalidJWTInstanceID
    case invalidJWTIssuer
    case invalidJWTTimestamps
}

public struct ValidatedRelayAccess: Equatable, Sendable {
    public let relayOrigin: String
    public let instanceID: String
    public let deviceToken: String
    public let expiresAt: Date
    public let expiresAtString: String

    public init(
        relayOrigin: String,
        instanceID: String,
        deviceToken: String,
        expiresAt: Date,
        expiresAtString: String
    ) {
        self.relayOrigin = relayOrigin
        self.instanceID = instanceID
        self.deviceToken = deviceToken
        self.expiresAt = expiresAt
        self.expiresAtString = expiresAtString
    }
}

public enum JournalRelayAccessValidator {
    private static let allowedJWTKeys: Set<String> = [
        "iss", "sub", "aud", "scope", "ver", "instance_id", "iat", "exp", "jti"
    ]

    public static func validateReadyResponse(
        protocolVersion: Int,
        status: String,
        relayOrigin: String,
        instanceID: String,
        deviceToken: String,
        expiresAtString: String,
        pairedInstanceID: String,
        now: Date = Date()
    ) throws -> ValidatedRelayAccess {
        guard protocolVersion == 2 else {
            throw JournalRelayAccessValidationError.invalidProtocolVersion
        }
        guard status == "ready" else {
            throw JournalRelayAccessValidationError.invalidStatus
        }
        guard instanceID.caseInsensitiveCompare(pairedInstanceID) == .orderedSame else {
            throw JournalRelayAccessValidationError.instanceMismatch
        }

        // Validate relay origin: replicate spl-swift 0.4.0 RelayEndpoint policy (https/wss with non-empty host).
        guard isValidRelayOrigin(relayOrigin) else {
            throw JournalRelayAccessValidationError.invalidRelayOrigin
        }

        guard let parsedExpiry = parseRFC3339(expiresAtString) else {
            throw JournalRelayAccessValidationError.invalidRFC3339Expiry
        }

        let jwtClaims = try validateJWT(
            token: deviceToken,
            pairedInstanceID: pairedInstanceID,
            now: now
        )

        let expirySeconds = Int(parsedExpiry.timeIntervalSince1970)
        guard expirySeconds == jwtClaims.exp else {
            throw JournalRelayAccessValidationError.expiryJWTExpMismatch
        }

        guard parsedExpiry.timeIntervalSince(now) > 0 else {
            throw JournalRelayAccessValidationError.expiredOrUnusable
        }

        return ValidatedRelayAccess(
            relayOrigin: relayOrigin,
            instanceID: instanceID,
            deviceToken: deviceToken,
            expiresAt: parsedExpiry,
            expiresAtString: expiresAtString
        )
    }

    public static func isValidRelayOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return scheme == "https" || scheme == "wss"
    }

    public static func parseRFC3339(_ string: String) -> Date? {
        let formatterWithMillis = ISO8601DateFormatter()
        formatterWithMillis.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithMillis.date(from: string) {
            return date
        }
        let formatterNoMillis = ISO8601DateFormatter()
        formatterNoMillis.formatOptions = [.withInternetDateTime]
        return formatterNoMillis.date(from: string)
    }

    public struct DecodedJWTClaims: Equatable, Sendable {
        public let iss: String
        public let sub: String
        public let aud: String
        public let scope: String
        public let ver: Int
        public let instanceID: String
        public let iat: Int
        public let exp: Int
        public let jti: String?
    }

    public static func validateJWT(
        token: String,
        pairedInstanceID: String,
        now: Date
    ) throws -> DecodedJWTClaims {
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3 else {
            throw JournalRelayAccessValidationError.invalidJWTFormat
        }

        guard let payloadData = base64URLDecode(parts[1]) else {
            throw JournalRelayAccessValidationError.invalidJWTPayloadEncoding
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: payloadData),
              let dict = jsonObject as? [String: Any]
        else {
            throw JournalRelayAccessValidationError.invalidJWTPayloadJSON
        }

        // Strict claim rejection: exact claim set match only (reject any missing or extra keys).
        let keys = Set(dict.keys)
        guard keys == allowedJWTKeys else {
            throw JournalRelayAccessValidationError.unexpectedJWTClaims
        }

        let ver = (dict["ver"] as? NSNumber)?.intValue ?? (dict["ver"] as? Int)
        guard ver == 2 else {
            throw JournalRelayAccessValidationError.invalidJWTVersion
        }

        guard let aud = dict["aud"] as? String, aud == "spl-relay" else {
            throw JournalRelayAccessValidationError.invalidJWTAudience
        }

        guard let scope = dict["scope"] as? String, scope == "session.dial" else {
            throw JournalRelayAccessValidationError.invalidJWTScope
        }

        guard let sub = dict["sub"] as? String, sub == "instance:\(pairedInstanceID)" else {
            throw JournalRelayAccessValidationError.invalidJWTSubject
        }

        guard let instanceID = dict["instance_id"] as? String,
              instanceID.caseInsensitiveCompare(pairedInstanceID) == .orderedSame
        else {
            throw JournalRelayAccessValidationError.invalidJWTInstanceID
        }

        guard let iss = dict["iss"] as? String, !iss.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JournalRelayAccessValidationError.invalidJWTIssuer
        }

        let iat = (dict["iat"] as? NSNumber)?.intValue ?? (dict["iat"] as? Int)
        let exp = (dict["exp"] as? NSNumber)?.intValue ?? (dict["exp"] as? Int)
        guard let iat, let exp, exp > iat else {
            throw JournalRelayAccessValidationError.invalidJWTTimestamps
        }

        let nowSeconds = Int(now.timeIntervalSince1970)
        guard exp > nowSeconds else {
            throw JournalRelayAccessValidationError.expiredOrUnusable
        }

        guard let jti = dict["jti"] as? String, !jti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JournalRelayAccessValidationError.unexpectedJWTClaims
        }

        return DecodedJWTClaims(
            iss: iss,
            sub: sub,
            aud: aud,
            scope: scope,
            ver: ver ?? 2,
            instanceID: instanceID,
            iat: iat,
            exp: exp,
            jti: jti
        )
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
