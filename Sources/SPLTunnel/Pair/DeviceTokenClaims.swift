// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct DeviceTokenClaims: Sendable, Equatable {
    public let issuedAt: Date
    public let expiresAt: Date

    public static func parse(_ token: String) -> DeviceTokenClaims? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 3 else {
            return nil
        }

        let payload = String(segments[1])
        guard !payload.isEmpty,
              let data = Self.base64URLDecode(payload)
        else {
            return nil
        }

        do {
            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            return DeviceTokenClaims(
                issuedAt: Date(timeIntervalSince1970: decoded.iat),
                expiresAt: Date(timeIntervalSince1970: decoded.exp)
            )
        } catch {
            return nil
        }
    }

    public static func needsRefresh(token: String?, now: Date) -> Bool {
        guard let token,
              let claims = Self.parse(token)
        else {
            return true
        }
        return claims.needsRefresh(now: now)
    }

    public func needsRefresh(now: Date) -> Bool {
        let ttl = expiresAt.timeIntervalSince(issuedAt)
        guard ttl > 0 else {
            return true
        }
        let age = now.timeIntervalSince(issuedAt)
        return age / ttl > 0.80
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 {
            return nil
        }
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

private struct Payload: Decodable {
    let exp: Double
    let iat: Double
}
