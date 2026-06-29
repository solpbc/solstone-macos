// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum PairLinkKind: Sendable, Equatable, Hashable {
    case direct
    case relay
}

public struct PairCandidate: Sendable, Equatable, Hashable {
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

public struct PairURL: Sendable, Equatable, Hashable {
    private static let relayVersion: UInt8 = 0x03
    private static let directVersion: UInt8 = 0x04
    private static let multiVersion: UInt8 = 0x05

    public let version: UInt8
    public let kind: PairLinkKind
    public let addressBytes: [UInt8]
    public let candidates: [PairCandidate]
    public let nonceBytes: [UInt8]
    public let caFingerprintBytes: [UInt8]
    public let caFingerprintKind: PairingCAPinKind
    public let instanceID: String?
    public let totp: String?
    public let relayOrigin: URL?

    public var caPin: PairingCAPin {
        PairingCAPin(kind: caFingerprintKind, prefixBytes: caFingerprintBytes)
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
        guard url.host?.lowercased() == "go.solstone.app" else {
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

        switch bytes[0] {
        case Self.directVersion:
            try self.init(directBytes: bytes)
        case Self.multiVersion:
            try self.init(multiBytes: bytes)
        case Self.relayVersion:
            try self.init(relayBytes: bytes)
        default:
            throw PairURLError.invalidVersion(bytes[0])
        }
    }

    private init(directBytes bytes: [UInt8]) throws {
        guard bytes.count >= 2 else {
            throw PairURLError.invalidLength(bytes.count)
        }
        guard bytes[1] == 0x01 else {
            throw PairURLError.unsupportedAddrType(bytes[1])
        }
        guard bytes.count == 40 else {
            throw PairURLError.invalidLength(bytes.count)
        }

        let parsedAddressBytes = Array(bytes[2..<6])
        let parsedPort = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let address = parsedAddressBytes.map(String.init).joined(separator: ".")

        version = bytes[0]
        kind = .direct
        addressBytes = parsedAddressBytes
        candidates = [PairCandidate(address: address, port: parsedPort)]
        nonceBytes = Array(bytes[8..<24])
        caFingerprintBytes = Array(bytes[24..<40])
        caFingerprintKind = .certificateSHA256
        instanceID = nil
        totp = nil
        relayOrigin = nil
    }

    private init(multiBytes bytes: [UInt8]) throws {
        guard bytes.count >= 3 else {
            throw PairURLError.invalidLength(bytes.count)
        }
        guard bytes[1] == 0x01 else {
            throw PairURLError.unsupportedAddrType(bytes[1])
        }
        let count = Int(bytes[2])
        guard count != 0 else {
            throw PairURLError.invalidLength(bytes.count)
        }
        guard bytes.count == 5 + 4 * count + 32 else {
            throw PairURLError.invalidLength(bytes.count)
        }

        let parsedPort = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
        var parsedCandidates: [PairCandidate] = []
        parsedCandidates.reserveCapacity(count)
        for index in 0..<count {
            let start = 5 + 4 * index
            let address = bytes[start..<(start + 4)].map(String.init).joined(separator: ".")
            parsedCandidates.append(PairCandidate(address: address, port: parsedPort))
        }

        let nonceStart = 5 + 4 * count
        let fingerprintStart = nonceStart + 16

        version = bytes[0]
        kind = .direct
        addressBytes = Array(bytes[5..<9])
        candidates = parsedCandidates
        nonceBytes = Array(bytes[nonceStart..<fingerprintStart])
        caFingerprintBytes = Array(bytes[fingerprintStart..<bytes.endIndex])
        caFingerprintKind = .certificateSHA256
        instanceID = nil
        totp = nil
        relayOrigin = nil
    }

    private init(relayBytes bytes: [UInt8]) throws {
        guard bytes.count >= 54 else {
            throw PairURLError.invalidLength(bytes.count)
        }
        guard bytes[36] == 0x01 else {
            throw PairURLError.unsupportedCAFingerprintTag(bytes[36])
        }
        let selectorLength = Int(bytes[53])
        guard bytes.count == 54 + selectorLength else {
            throw PairURLError.invalidLength(bytes.count)
        }

        let instanceBytes = Array(bytes[1..<17])
        let uuid = UUID(uuid: (
            instanceBytes[0], instanceBytes[1], instanceBytes[2], instanceBytes[3],
            instanceBytes[4], instanceBytes[5], instanceBytes[6], instanceBytes[7],
            instanceBytes[8], instanceBytes[9], instanceBytes[10], instanceBytes[11],
            instanceBytes[12], instanceBytes[13], instanceBytes[14], instanceBytes[15]
        ))
        let totpValue = Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])

        let relayOrigin: URL?
        if selectorLength == 0 {
            relayOrigin = nil
        } else {
            let selectorBytes = bytes[54..<(54 + selectorLength)]
            guard let selector = String(bytes: selectorBytes, encoding: .utf8),
                  let url = URL(string: selector),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss",
                  url.host != nil else {
                throw PairURLError.invalidRelayOrigin
            }
            relayOrigin = url
        }

        version = bytes[0]
        kind = .relay
        addressBytes = []
        candidates = []
        nonceBytes = Array(bytes[20..<36])
        caFingerprintBytes = Array(bytes[37..<53])
        caFingerprintKind = .spkiSHA256
        instanceID = uuid.uuidString.lowercased()
        totp = String(format: "%06d", totpValue)
        self.relayOrigin = relayOrigin
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
    case unsupportedCAFingerprintTag(UInt8)
    case invalidRelayOrigin
    case invalidLength(Int)
    case malformedOuterURL

    public enum Base32Reason: Error, Equatable, Sendable {
        case outOfAlphabet(Character)
        case nonCanonicalPadBits
    }
}
