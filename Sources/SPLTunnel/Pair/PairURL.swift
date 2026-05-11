// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct PairURL: Sendable, Equatable {
    public let homeURL: URL
    public let token: String
    public let caFingerprintHex: String
    public let label: String
    public let version: Int

    public static func parse(_ url: URL) throws -> PairURL {
        try PairURL(url: url)
    }

    public init(string: String) throws {
        guard let url = URL(string: string) else {
            throw PairURLError.malformedHomeURL
        }
        try self.init(url: url)
    }

    public init(url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw PairURLError.wrongScheme
        }
        guard url.host?.lowercased() == "link.solpbc.org" else {
            throw PairURLError.wrongHost
        }
        guard url.path == "/p" else {
            throw PairURLError.wrongPath
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.percentEncodedFragment,
              !fragment.isEmpty else {
            throw PairURLError.missingFragment
        }

        let fields = try Self.fragmentFields(fragment)
        guard let homeValue = fields["h"] else {
            throw PairURLError.missingField("h")
        }
        guard let token = fields["t"] else {
            throw PairURLError.missingField("t")
        }
        guard let fingerprint = fields["f"] else {
            throw PairURLError.missingField("f")
        }
        guard let label = fields["l"] else {
            throw PairURLError.missingField("l")
        }
        guard fields["v"] == "1" else {
            throw PairURLError.invalidVersion
        }

        guard let homeURL = URL(string: homeValue),
              let host = homeURL.host,
              !host.isEmpty else {
            throw PairURLError.malformedHomeURL
        }
        guard homeURL.scheme?.lowercased() == "https" else {
            throw PairURLError.nonHTTPSHomeURL
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairURLError.emptyToken
        }
        guard Self.isValidFingerprint(fingerprint) else {
            throw PairURLError.invalidFingerprint
        }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairURLError.emptyLabel
        }

        self.homeURL = homeURL
        self.token = token
        self.caFingerprintHex = fingerprint.lowercased()
        self.label = label
        self.version = 1
    }

    init(homeURL: URL, token: String, caFingerprintHex: String, label: String, version: Int = 1) {
        self.homeURL = homeURL
        self.token = token
        self.caFingerprintHex = caFingerprintHex.lowercased()
        self.label = label
        self.version = version
    }

    private static func fragmentFields(_ fragment: String) throws -> [String: String] {
        var fields: [String: String] = [:]
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let name = percentDecode(String(parts[0])),
                  let value = percentDecode(String(parts[1])) else {
                throw PairURLError.missingFragment
            }
            fields[name] = value
        }
        return fields
    }

    private static func percentDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func isValidFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character.lowercased())
        }
    }
}

public enum PairURLError: Error, Equatable, Sendable {
    case wrongScheme
    case wrongHost
    case wrongPath
    case missingFragment
    case missingField(String)
    case invalidVersion
    case malformedHomeURL
    case nonHTTPSHomeURL
    case invalidFingerprint
    case emptyToken
    case emptyLabel
}
