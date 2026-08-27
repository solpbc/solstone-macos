// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

public protocol JournalRuntimeEntryCandidateProvenanceResolving: Sendable {
    func resolve(for appIdentity: JournalRuntimeEntryReceiptAppIdentity) -> JournalRuntimeEntryCandidateProvenance?
}

public struct BundledJournalRuntimeEntryCandidateProvenanceResolver: JournalRuntimeEntryCandidateProvenanceResolving {
    private static let resourceSubdirectory = "Resources"
    private let resourceURLs: @Sendable () -> [URL]

    public init(bundle: Bundle = .main) {
        let resourceURLs = bundle.urls(
            forResourcesWithExtension: "json",
            subdirectory: Self.resourceSubdirectory
        ) ?? []
        self.resourceURLs = {
            resourceURLs
        }
    }

    init(resourceURLs: @escaping @Sendable () -> [URL]) {
        self.resourceURLs = resourceURLs
    }

    public func resolve(for appIdentity: JournalRuntimeEntryReceiptAppIdentity) -> JournalRuntimeEntryCandidateProvenance? {
        let urls = resourceURLs()
        guard urls.count == 1, let data = try? Data(contentsOf: urls[0]),
              let object = strictJSONObject(data),
              let provenance = parse(object: object),
              provenance.target.bundleIdentifier == appIdentity.bundleIdentifier,
              provenance.target.bundleShortVersion == appIdentity.bundleShortVersion,
              provenance.target.bundleVersion == appIdentity.bundleVersion else {
            Logger.journalRuntimeEntryReceipts.warning("candidate provenance rejected")
            return nil
        }
        return provenance
    }

    private func parse(object: [String: Any]) -> JournalRuntimeEntryCandidateProvenance? {
        let allowed = [
            "schema", "schema_version", "source", "target", "runtime_archive_sha256",
            "manifest_sha256", "release_receipt_sha256", "signing_receipt_sha256", "runtime_tree_sha256"
        ]
        guard Set(object.keys) == Set(allowed),
              object["schema"] as? String == "journal-runtime-entry-candidate-provenance",
              integer(object["schema_version"]) == 1,
              object["source"] as? String == "J",
              let targetObject = object["target"] as? [String: Any],
              Set(targetObject.keys) == ["bundle_identifier", "bundle_short_version", "bundle_version"],
              let bundleIdentifier = nonEmpty(targetObject["bundle_identifier"]),
              let bundleShortVersion = nonEmpty(targetObject["bundle_short_version"]),
              let bundleVersion = nonEmpty(targetObject["bundle_version"]),
              let runtimeArchive = digest(object["runtime_archive_sha256"]),
              let manifest = digest(object["manifest_sha256"]),
              let releaseReceipt = digest(object["release_receipt_sha256"]),
              let signingReceipt = digest(object["signing_receipt_sha256"]),
              let runtimeTree = digest(object["runtime_tree_sha256"]) else {
            return nil
        }
        return JournalRuntimeEntryCandidateProvenance(
            source: "J",
            target: JournalRuntimeEntryCandidateTarget(
                bundleIdentifier: bundleIdentifier,
                bundleShortVersion: bundleShortVersion,
                bundleVersion: bundleVersion
            ),
            runtimeArchiveSHA256: runtimeArchive,
            manifestSHA256: manifest,
            releaseReceiptSHA256: releaseReceipt,
            signingReceiptSHA256: signingReceipt,
            runtimeTreeSHA256: runtimeTree
        )
    }
}

func strictJSONObject(_ data: Data) -> [String: Any]? {
    guard JSONDuplicateKeyDetector.hasNoDuplicateKeys(in: data),
          let object = try? JSONSerialization.jsonObject(with: data, options: []),
          let dictionary = object as? [String: Any] else {
        return nil
    }
    return dictionary
}

private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded() == double else { return nil }
    return Int(exactly: double)
}

private func nonEmpty(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func digest(_ value: Any?) -> String? {
    guard let value = value as? String,
          value.count == 64,
          value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
        return nil
    }
    return value
}

private enum JSONDuplicateKeyDetector {
    static func hasNoDuplicateKeys(in data: Data) -> Bool {
        var parser = Parser(bytes: Array(data))
        return parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() -> Bool {
            skipWhitespace()
            guard parseValue() else { return false }
            skipWhitespace()
            return index == bytes.count
        }

        mutating func parseValue() -> Bool {
            skipWhitespace()
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case 123: return parseObject()
            case 91: return parseArray()
            case 34: return parseString() != nil
            case 116: return consume("true")
            case 102: return consume("false")
            case 110: return consume("null")
            case 45, 48...57: return parseNumber()
            default: return false
            }
        }

        mutating func parseObject() -> Bool {
            index += 1
            skipWhitespace()
            if consumeByte(125) { return true }
            var keys = Set<String>()
            while true {
                guard let key = parseString(), keys.insert(key).inserted else { return false }
                skipWhitespace()
                guard consumeByte(58), parseValue() else { return false }
                skipWhitespace()
                if consumeByte(125) { return true }
                guard consumeByte(44) else { return false }
                skipWhitespace()
            }
        }

        mutating func parseArray() -> Bool {
            index += 1
            skipWhitespace()
            if consumeByte(93) { return true }
            while true {
                guard parseValue() else { return false }
                skipWhitespace()
                if consumeByte(93) { return true }
                guard consumeByte(44) else { return false }
                skipWhitespace()
            }
        }

        mutating func parseString() -> String? {
            guard consumeByte(34) else { return nil }
            var result = ""
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 { return result }
                if byte == 92 {
                    guard index < bytes.count else { return nil }
                    let escaped = bytes[index]
                    index += 1
                    switch escaped {
                    case 34: result.append("\"")
                    case 92: result.append("\\")
                    case 47: result.append("/")
                    case 98: result.append("\u{08}")
                    case 102: result.append("\u{0C}")
                    case 110: result.append("\n")
                    case 114: result.append("\r")
                    case 116: result.append("\t")
                    case 117:
                        guard index + 4 <= bytes.count,
                              let scalar = UInt32(String(bytes: bytes[index..<(index + 4)], encoding: .utf8) ?? "", radix: 16),
                              let unicode = UnicodeScalar(scalar) else { return nil }
                        result.unicodeScalars.append(unicode)
                        index += 4
                    default: return nil
                    }
                } else {
                    guard byte >= 32 else { return nil }
                    result.append(Character(UnicodeScalar(byte)))
                }
            }
            return nil
        }

        mutating func parseNumber() -> Bool {
            let start = index
            if consumeByte(45) {}
            guard consumeDigits() else { return false }
            if consumeByte(46), !consumeDigits() { return false }
            if index < bytes.count, bytes[index] == 69 || bytes[index] == 101 {
                index += 1
                if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                guard consumeDigits() else { return false }
            }
            return index > start
        }

        mutating func consumeDigits() -> Bool {
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            return index > start
        }

        mutating func consume(_ text: String) -> Bool {
            let expected = Array(text.utf8)
            guard bytes[index...].starts(with: expected) else { return false }
            index += expected.count
            return true
        }

        mutating func consumeByte(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
    }
}
