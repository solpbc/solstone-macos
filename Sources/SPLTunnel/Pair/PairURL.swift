// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Parses v1 LAN pair URLs. The local-network allow-list intentionally mirrors
/// `UploadClient.isLocalNetworkHost`: in practice pairing may use Bonjour names,
/// bare hostnames, IPv4/IPv6 link-local, or Tailscale/CGNAT routes.
public struct PairURL: Sendable, Equatable {
    public let lanURL: URL
    public let nonce: String
    public let caFingerprintHex: String

    public init(splURL: URL) throws {
        guard splURL.scheme?.lowercased() == "spl" else {
            throw PairURLError.wrongScheme
        }
        guard splURL.host?.lowercased() == "pair" else {
            throw PairURLError.wrongHost
        }
        guard let components = URLComponents(url: splURL, resolvingAgainstBaseURL: false) else {
            throw PairURLError.wrongHost
        }
        let items = components.queryItems ?? []
        guard let encodedURL = items.first(where: { $0.name == "u" })?.value else {
            throw PairURLError.missingU
        }
        guard let encodedPin = items.first(where: { $0.name == "pin" })?.value else {
            throw PairURLError.missingPin
        }
        guard let lanURLData = Self.base64urlDecode(encodedURL),
              let lanURLString = String(data: lanURLData, encoding: .utf8),
              let lanURL = URL(string: lanURLString),
              let lanComponents = URLComponents(url: lanURL, resolvingAgainstBaseURL: false),
              let host = lanURL.host,
              !host.isEmpty else {
            throw PairURLError.malformedLanURL
        }
        guard lanURL.scheme?.lowercased() == "https" else {
            throw PairURLError.nonHTTPSLanURL
        }
        guard Self.isLocalNetworkHost(host) else {
            throw PairURLError.nonLocalHost
        }
        guard let token = lanComponents.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            throw PairURLError.missingToken
        }
        guard let pinBytes = Self.base64urlDecode(encodedPin) else {
            throw PairURLError.malformedBase64URL
        }
        guard pinBytes.count == 32 else {
            throw PairURLError.invalidPinLength
        }

        self.lanURL = lanURL
        self.nonce = token
        self.caFingerprintHex = CertChain.hex(pinBytes)
    }

    private static func base64urlDecode(_ value: String) -> Data? {
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=" }) else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            return false
        }

        let normalizedHost = trimmedHost.hasSuffix(".") ? String(trimmedHost.dropLast()) : trimmedHost
        let lowercaseHost = normalizedHost.lowercased()

        if lowercaseHost == "localhost" || lowercaseHost == "::1" {
            return false
        }

        if lowercaseHost.contains(":") {
            if lowercaseHost.hasPrefix("fe80:") {
                return true
            }

            if lowercaseHost.hasPrefix("fc") || lowercaseHost.hasPrefix("fd") {
                return true
            }

            return false
        }

        let parts = lowercaseHost.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let octets = parts.compactMap { Int($0) }
            guard octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) else {
                return false
            }

            switch (octets[0], octets[1]) {
            case (127, _):
                return false
            case (10, _):
                return true
            case (172, 16...31):
                return true
            case (192, 168):
                return true
            case (169, 254):
                return true
            case (100, 64...127):
                return true
            default:
                return false
            }
        }

        if lowercaseHost.hasSuffix(".local") {
            return true
        }

        return !lowercaseHost.contains(".")
    }
}

public enum PairURLError: Error, Equatable, Sendable {
    case wrongScheme
    case wrongHost
    case missingU
    case missingPin
    case malformedBase64URL
    case malformedLanURL
    case nonHTTPSLanURL
    case missingToken
    case invalidPinLength
    case nonLocalHost
}
