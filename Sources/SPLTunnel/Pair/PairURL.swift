// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct PairURL: Sendable, Equatable, Hashable {
    public let version: UInt8
    public let addressBytes: [UInt8]
    public let port: UInt16
    public let nonceBytes: [UInt8]
    public let caFingerprintBytes: [UInt8]

    public var addressString: String {
        addressBytes.map(String.init).joined(separator: ".")
    }

    public static func parse(_ url: URL) throws -> PairURL {
        try PairURL(url: url)
    }

    public init(string: String) throws {
        guard let url = URL(string: string) else {
            throw PairURLError.malformedOuterURL
        }
        try self.init(url: url)
    }

    public init(url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw PairURLError.wrongScheme(url.scheme)
        }
        guard url.host?.lowercased() == "link.solpbc.org" else {
            throw PairURLError.wrongHost(url.host)
        }
        guard url.path == "/p" else {
            throw PairURLError.wrongPath(url.path)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.percentEncodedFragment,
              !fragment.isEmpty else {
            throw PairURLError.missingFragment
        }

        let bytes: [UInt8]
        do {
            bytes = try Crockford32.decode(fragment)
        } catch let reason as PairURLError.Base32Reason {
            throw PairURLError.invalidBase32(reason)
        }

        guard !bytes.isEmpty else {
            throw PairURLError.invalidLength(bytes.count)
        }
        guard bytes[0] == 0x04 else {
            throw PairURLError.invalidVersion(bytes[0])
        }
        guard bytes.count >= 2 else {
            throw PairURLError.invalidLength(bytes.count)
        }
        guard bytes[1] == 0x01 else {
            throw PairURLError.unsupportedAddrType(bytes[1])
        }
        guard bytes.count == 40 else {
            throw PairURLError.invalidLength(bytes.count)
        }

        version = bytes[0]
        addressBytes = Array(bytes[2..<6])
        port = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        nonceBytes = Array(bytes[8..<24])
        caFingerprintBytes = Array(bytes[24..<40])
    }
}

public enum PairURLError: Error, Equatable, Sendable {
    case wrongScheme(String?)
    case wrongHost(String?)
    case wrongPath(String)
    case missingFragment
    case invalidBase32(Base32Reason)
    case invalidVersion(UInt8)
    case unsupportedAddrType(UInt8)
    case invalidLength(Int)
    case malformedOuterURL

    public enum Base32Reason: Error, Equatable, Sendable {
        case outOfAlphabet(Character)
        case nonCanonicalPadBits
    }
}
