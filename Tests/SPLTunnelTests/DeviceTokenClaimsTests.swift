// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SPLTunnel

@Suite("DeviceTokenClaims")
struct DeviceTokenClaimsTests {
    @Test func parseValidToken() throws {
        let token = Self.token(payload: ["iat": 1_000.0, "exp": 2_000.0])

        let claims = try #require(DeviceTokenClaims.parse(token))

        #expect(claims.issuedAt == Date(timeIntervalSince1970: 1_000))
        #expect(claims.expiresAt == Date(timeIntervalSince1970: 2_000))
    }

    @Test func needsRefreshForMalformedShortMissingClaimsAndBadTTL() {
        #expect(DeviceTokenClaims.needsRefresh(token: nil, now: Date(timeIntervalSince1970: 1_500)))
        #expect(DeviceTokenClaims.needsRefresh(token: "not-a-jwt", now: Date(timeIntervalSince1970: 1_500)))
        #expect(DeviceTokenClaims.needsRefresh(token: Self.token(payload: ["iat": 1_000.0]), now: Date(timeIntervalSince1970: 1_500)))
        #expect(DeviceTokenClaims.needsRefresh(token: Self.token(payload: ["exp": 2_000.0]), now: Date(timeIntervalSince1970: 1_500)))
        #expect(DeviceTokenClaims.needsRefresh(token: Self.token(payload: ["iat": 2_000.0, "exp": 1_000.0]), now: Date(timeIntervalSince1970: 1_500)))
    }

    @Test func needsRefreshBoundaryUsesStrictlyGreaterThanEightyPercent() throws {
        let claims = try #require(DeviceTokenClaims.parse(Self.token(payload: ["iat": 1_000.0, "exp": 2_000.0])))

        #expect(!claims.needsRefresh(now: Date(timeIntervalSince1970: 1_799)))
        #expect(!claims.needsRefresh(now: Date(timeIntervalSince1970: 1_800)))
        #expect(claims.needsRefresh(now: Date(timeIntervalSince1970: 1_801)))
    }

    static func token(payload: [String: Double]) -> String {
        "e30.\(Self.base64URL(payload)).sig"
    }

    private static func base64URL(_ object: [String: Double]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
